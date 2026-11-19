# helios-contract

The contract between [helios](https://github.com/kench/helios) (the on-device agent) and
[helios-cloud](https://github.com/kench/helios-cloud) (the cloud side). It is the single
source of truth for:

- the **Bootstrap API**: the device API (`HeliosBootstrap`) and the admin API
  (`HeliosBootstrapAdmin`), modelled in [Smithy](https://smithy.io/),
- the **challenge test vectors**, used by both sides to test the signed bootstrap challenge,
- later, the MQTT message shapes from the messaging design (LLD 2).

Design docs (Notion): *Helios - Bootstrap API* and *Helios - LLD 1*, section 4.8.

> **Status:** first draft. The model hasn't been run through `smithy build` yet. Run it before
> the first tagged release and fix anything the validators report.

## Layout

```
model/
  common.smithy      shapes shared by both services (MAC, thing name, PIN, errors, ...)
  bootstrap.smithy   device API: Bootstrap, AnswerChallenge, plus protocol tests
  admin.smithy       admin API: the Device resource and its operations
smithy-build.json    build config: OpenAPI 3.1 output for each service
test-vectors/
  challenge-v1.json  challenge message, digest and signature vectors (TEST KEY ONLY)
scripts/
  generate_challenge_vectors.py   regenerates challenge-v1.json
```

## Protocol and wire format

Both services use `aws.protocols#restJson1`, which works for any HTTP/JSON service, not only
AWS ones. In practice that means:

- JSON member names are the Smithy member names (camelCase), for example `heliosVersion`.
- Blobs (`nonce`, `signature`) are base64 strings. Timestamps use `@timestampFormat("date-time")`
  (RFC 3339).
- `Bootstrap` returns a union as the whole body: `{"identity": {...}}` or
  `{"challenge": {...}}`. `AnswerChallenge` returns the identity object itself.
- Errors use the HTTP status from `@httpError` and name the error in the `X-Amzn-Errortype`
  header (for example `DeviceDisabled`). Several errors share 403, so clients go by the
  error type, not only the status code.
- Invalid input is rejected with `smithy.framework#ValidationException` (400).
- The admin API uses SigV4 (`@sigv4(name: "execute-api")`), matching IAM authorization on
  API Gateway. The device API has no authentication.
- `Pin` is `@sensitive`, so generated code redacts it from `toString` and logs.

## Building

```sh
smithy build        # needs the Smithy CLI; Maven dependencies come from smithy-build.json
```

The outputs go to `build/smithy/<projection>/openapi/`:

- `device-api`: OpenAPI 3.1 for `HeliosBootstrap`
- `admin-api`: OpenAPI 3.1 for `HeliosBootstrapAdmin`

The schemas in the OpenAPI output are JSON Schema 2020-12. The `helios` Rust client checks its
hand-written `serde` types against them and against the protocol-test bodies in the model.

## How the other repositories use this one

Both include this repository as a **git submodule pinned to a tagged release**, so a contract
change reaches each side only when that repository bumps the submodule.

- **helios-cloud** generates Java types from the model (Smithy Java type code generation, Java 21)
  for the bootstrap Lambdas, and can generate a Java client for the admin API (SigV4) for
  provisioning tools. The code generation config lives in helios-cloud, not here.
- **helios** uses hand-written Rust types for the two device operations, tested against the
  OpenAPI schemas, the protocol-test bodies and the challenge vectors.

## Challenge test vectors

`test-vectors/challenge-v1.json` holds:

- a P-256 **test** key pair (committed on purpose, never to be registered for a real device),
- a challenge (`challengeId`, `nonce`) and the request's adapters,
- one signature in DER (base64) and raw `r||s` (hex) form, for testing the PKCS#11
  raw-to-DER conversion,
- cases with the exact message bytes and SHA-256 digest, and whether the signature should
  verify: `valid`, `different-macs` and `different-nonce`.

The message is:

```
helios-bootstrap-v1\n<challengeId>\n<nonce base64, as received>\n<MACs sorted ascending, joined with ",">
```

with no trailing newline. To regenerate (this creates a new key and new signatures):

```sh
python3 scripts/generate_challenge_vectors.py > test-vectors/challenge-v1.json
```

## Versioning

- The API version is in the path (`/v1`). Within v1, changes may only add things: new optional
  members, new operations, new enum values. Clients ignore unknown members and must cope with
  unknown enum values.
- Each tag on this repository is a release that `helios` and `helios-cloud` can pin.

## To do

- [ ] Run `smithy build` and fix validator findings.
- [ ] CI: run `smithy build`, check the challenge vectors, and attach the OpenAPI outputs to
      each tagged release.
- [ ] Add the MQTT message shapes from LLD 2.

## License

[CC0 1.0 Universal](LICENSE).
