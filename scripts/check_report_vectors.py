#!/usr/bin/env python3
"""Checks the report vectors (test-vectors/control-reports-v*.json) against the Control API's
OpenAPI document (smithy build's HeliosControl.openapi.json):

- every case has a name, a GET request on one of the API's paths, the `reported` sections of
  known shadows, and a response with a status;
- that status is one the operation can answer, and an error's type matches the schema the
  operation names for it;
- a 200 response's body validates against the operation's 200 schema.

The validator covers the parts of JSON Schema that Smithy's OpenAPI output uses (type,
properties, required, items, enum, pattern, minimum, maximum, minLength, maxLength, oneOf,
$ref). Usage: check_report_vectors.py <HeliosControl.openapi.json> <vectors.json>...
"""

import json
import re
import sys

SHADOWS = {"stream", "net", "gps", "helios"}


class Invalid(Exception):
    pass


def resolve(spec, schema):
    while "$ref" in schema:
        name = schema["$ref"].removeprefix("#/components/schemas/")
        schema = spec["components"]["schemas"][name]
    return schema


def validate(spec, schema, value, where):
    schema = resolve(spec, schema)
    if "oneOf" in schema:
        matches = 0
        for option in schema["oneOf"]:
            try:
                validate(spec, option, value, where)
                matches += 1
            except Invalid:
                pass
        if matches != 1:
            raise Invalid(f"{where}: matches {matches} of oneOf's options, not exactly one")
        return
    kind = schema.get("type")
    if kind == "object" or "properties" in schema:
        if not isinstance(value, dict):
            raise Invalid(f"{where}: not an object")
        properties = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                raise Invalid(f"{where}: {name} is required")
        extra = schema.get("additionalProperties")
        for name, member in value.items():
            if name in properties:
                validate(spec, properties[name], member, f"{where}.{name}")
            elif isinstance(extra, dict):
                validate(spec, extra, member, f"{where}.{name}")
            elif properties:
                raise Invalid(f"{where}: unknown member {name}")
    elif kind == "array":
        if not isinstance(value, list):
            raise Invalid(f"{where}: not an array")
        for i, item in enumerate(value):
            validate(spec, schema.get("items", {}), item, f"{where}[{i}]")
    elif kind == "string":
        if not isinstance(value, str):
            raise Invalid(f"{where}: not a string")
        if "enum" in schema and value not in schema["enum"]:
            raise Invalid(f"{where}: {value!r} isn't one of {schema['enum']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise Invalid(f"{where}: {value!r} doesn't match {schema['pattern']}")
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get(
            "maxLength", len(value)
        ):
            raise Invalid(f"{where}: length {len(value)} is out of range")
    elif kind in ("number", "integer"):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise Invalid(f"{where}: not a number")
        if value < schema.get("minimum", value) or value > schema.get("maximum", value):
            raise Invalid(f"{where}: {value} is out of range")
    elif kind == "boolean":
        if not isinstance(value, bool):
            raise Invalid(f"{where}: not a boolean")


def operation(spec, path):
    get = spec["paths"].get(path, {}).get("get")
    if get is None:
        raise Invalid(f"no GET {path} in the API")
    return get


def check_case(spec, case):
    name = case.get("name")
    if not isinstance(name, str) or not name:
        raise Invalid("a case has no name")
    request = case.get("request", {})
    if request.get("method") != "GET":
        raise Invalid(f"{name}: only reads are vectors")
    op = operation(spec, request.get("path"))
    wanted = set(re.findall(r"\{(\w+)\}", request["path"])) - {"deviceId"}
    params = request.get("params", {})
    if set(params) != wanted or not all(isinstance(v, str) and v for v in params.values()):
        raise Invalid(f"{name}: params must give {sorted(wanted)}")
    reported = case.get("reported")
    if not isinstance(reported, dict) or not set(reported) <= SHADOWS:
        raise Invalid(f"{name}: reported must map shadow names {sorted(SHADOWS)} to objects")
    for shadow, value in reported.items():
        if not isinstance(value, dict):
            raise Invalid(f"{name}: reported.{shadow} isn't an object")
    response = case.get("response", {})
    status = str(response.get("status"))
    answer = op["responses"].get(status)
    if answer is None:
        raise Invalid(f"{name}: {op['operationId']} can't answer {status}")
    schema = answer.get("content", {}).get("application/json", {}).get("schema", {})
    if status == "200":
        if "errorType" in response:
            raise Invalid(f"{name}: a 200 has no error type")
        validate(spec, schema, response.get("body"), f"{name}.body")
        return
    error = schema.get("$ref", "").removeprefix("#/components/schemas/")
    error = error.removesuffix("ResponseContent")
    if response.get("errorType") != error:
        raise Invalid(f"{name}: {status} is {error}, not {response.get('errorType')}")
    if "body" in response:
        validate(spec, schema, response["body"], f"{name}.body")


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1]) as file:
        spec = json.load(file)
    failures = 0
    for path in argv[2:]:
        with open(path) as file:
            vectors = json.load(file)
        names = [case.get("name") for case in vectors["cases"]]
        if len(names) != len(set(names)):
            print(f"{path}: case names repeat")
            failures += 1
        for case in vectors["cases"]:
            try:
                check_case(spec, case)
                print(f"ok:      {case['name']}")
            except Invalid as error:
                print(f"invalid: {error}")
                failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
