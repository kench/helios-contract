#!/usr/bin/env python3
"""Checks the command vectors (test-vectors/*-commands-v*.json) against a reference reading of
model/device.smithy: every case marked valid must pass it and every invalid one must fail it.

The reference covers what the model says about the arguments' shape (required members,
unions with exactly one member, no unknown members, the patterns and ranges). The device
checks more (that a profile exists, a bitrate within the profile's limits), and that's tested
in Helios, not here.
"""

import json
import re
import sys

STREAM_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
PROFILE = STREAM_ID
DEVICE_SELECTOR = re.compile(
    r"^(usb:[0-9]+-[0-9]+(\.[0-9]+)*|[0-9a-fA-F]{4}:[0-9a-fA-F]{4}:[^\s]+)$"
)
RTMP_KEY = re.compile(r"^ingest(-[1-9][0-9]{0,2})?$")
SIZE = re.compile(r"^[0-9]{2,4}x[0-9]{2,4}$")


class Invalid(Exception):
    pass


def require(condition, why):
    if not condition:
        raise Invalid(why)


def members(value, allowed, required=()):
    require(isinstance(value, dict), "not an object")
    unknown = set(value) - set(allowed)
    require(not unknown, f"unknown members {sorted(unknown)}")
    for name in required:
        require(name in value, f"{name} is required")


def integer(value, low, high):
    require(isinstance(value, int) and not isinstance(value, bool), "not an integer")
    require(low <= value <= high, f"{value} outside {low}..{high}")


def string(value, pattern, low=1, high=1024):
    require(isinstance(value, str), "not a string")
    require(low <= len(value) <= high, "wrong length")
    require(pattern.match(value), f"{value!r} doesn't match")


def union(value, variants):
    require(isinstance(value, dict) and len(value) == 1, "a union has exactly one member")
    (name, inner), = value.items()
    require(name in variants, f"unknown union member {name}")
    variants[name](inner)


def unit(value):
    require(value == {}, "a Unit member is {}")


def source(value):
    def camera(v):
        members(v, ["video", "audio"], ["video"])
        string(v["video"], DEVICE_SELECTOR, 5, 200)
        if "audio" in v:
            string(v["audio"], DEVICE_SELECTOR, 5, 200)

    def rtmp(v):
        members(v, ["key"], ["key"])
        string(v["key"], RTMP_KEY)

    def test(v):
        members(v, ["size", "fps"])
        if "size" in v:
            string(v["size"], SIZE)
        if "fps" in v:
            integer(v["fps"], 1, 120)

    union(value, {"camera": camera, "rtmp": rtmp, "test": test})


def sealed(value):
    members(value, ["sealed"], ["sealed"])
    members(value["sealed"], ["enc", "ct"], ["enc", "ct"])
    for part in ("enc", "ct"):
        require(isinstance(value["sealed"][part], str) and value["sealed"][part], f"{part} is empty")


def setting(set_value):
    return lambda value: union(value, {"set": set_value, "configured": unit})


def boolean(value):
    require(isinstance(value, bool), "not a boolean")


UPDATE = {
    "source": setting(source),
    "profile": setting(lambda v: string(v, PROFILE, 1, 64)),
    "destination": setting(sealed),
    "bitrate": setting(lambda v: integer(v, 100, 100000)),
    "source_ceiling_percent": setting(lambda v: integer(v, 0, 400)),
    "record": setting(boolean),
}


def stream_only(args):
    members(args, ["stream_id"], ["stream_id"])
    string(args["stream_id"], STREAM_ID, 1, 64)


def update(args):
    members(args, ["stream_id", *UPDATE], ["stream_id"])
    string(args["stream_id"], STREAM_ID, 1, 64)
    for name, check in UPDATE.items():
        if name in args:
            check(args[name])


COMMANDS = {
    "helios-stream-start-v1": stream_only,
    "helios-stream-stop-v1": stream_only,
    "helios-stream-update-v1": update,
}


def main(paths):
    failures = 0
    for path in paths:
        with open(path, encoding="utf-8") as file:
            cases = json.load(file)["cases"]
        names = [case["name"] for case in cases]
        if len(names) != len(set(names)):
            print(f"{path}: duplicate case names")
            failures += 1
        for case in cases:
            check = COMMANDS.get(case["command"])
            if check is None:
                print(f"{path}: {case['name']}: unknown command {case['command']}")
                failures += 1
                continue
            try:
                check(case["args"])
                passed, why = True, ""
            except Invalid as error:
                passed, why = False, str(error)
            if passed != case["valid"]:
                expected = "valid" if case["valid"] else "invalid"
                print(f"{path}: {case['name']}: expected {expected}, reference says {why or 'valid'}")
                failures += 1
        print(f"{path}: {len(cases)} cases")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
