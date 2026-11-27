# helios-contract

The contract between [helios](https://github.com/kench/helios) (the on-device agent) and
[helios-cloud](https://github.com/kench/helios-cloud) (the cloud side). It is the single
source of truth for:

- the **Bootstrap API**: the device API (`HeliosBootstrap`) and the admin API
  (`HeliosBootstrapAdmin`), modelled in [Smithy](https://smithy.io/),
- the **Control API** (`HeliosControl`, namespace `tv.kenley.helios.control`): operators and
  agents see devices and their streams and start, stop and adjust them (HLD section 7.3),
- the **challenge test vectors**, used by both sides to test the signed bootstrap challenge,
- the **device commands** (`HeliosDeviceCommands`, namespace `tv.kenley.helios.device`): the
  AWS IoT commands the cloud sends a device (stream start, stop and update; the display's idle
  screen) and its answers, with argument test vectors. Writes
  to a device are commands, its shadows reported-only (Notion: *Helios - State Management:
  Tenets and Practices*). The reported shadows' shapes come later.

Design docs (Notion): *Helios - Bootstrap API*, *Helios - LLD 1*, section 4.8, and the HLD,
section 7.3 (the Control API).

> **Status:** draft. CI runs `smithy build` on every pull request; the model validates with no
> errors. The only warnings are `MemberShouldReferenceResource` on `deviceId` members, which
> Smithy raises because both the admin and control services have their own `Device` resource.

## Layout

```
model/
  common.smithy      shapes shared by both services (MAC, thing name, PIN, errors, ...)
  bootstrap.smithy   device API: Bootstrap, AnswerChallenge, plus protocol tests
  admin.smithy       admin API: the Device resource and its operations
  control.smithy     control API: devices, their inputs, profiles, location and uplinks, and the Stream resource
  device.smithy      device commands: stream start, stop and update (not an HTTP API)
smithy-build.json    build config: OpenAPI 3.1 output for each service
test-vectors/
  challenge-v1.json  challenge message, digest and signature vectors (TEST KEY ONLY)
  stream-commands-v1.json  valid and invalid arguments of the stream commands
scripts/
  generate_challenge_vectors.py   regenerates challenge-v1.json
  check_command_vectors.py        checks the command vectors against a reference reading of the model
  check_challenge_vectors.py      checks the vector files (run in CI)
  requirements.txt                Python dependencies for both scripts
.github/workflows/ci.yml          CI and releases
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
- The admin and control APIs use SigV4 (`@sigv4(name: "execute-api")`), matching IAM
  authorization on API Gateway (the control API's callers assume `helios-operator`). The device
  API has no authentication. All three are served by one API Gateway REST API, under
  `/v1/device`, `/v1/admin` and `/v1/control`.
- Control API changes (`StartStream`, `StopStream`, `UpdateStream`, `SetStreamDestination`)
  write the device's `stream` shadow and return 202: the device applies them when it can and
  reports the result in `GetStream` (`pending`, `rejected`). They take an optional
  `clientToken` (`@idempotencyToken`), so a retry is safe.
- Wi-Fi changes (`SetWifiNetwork`, `DeleteWifiNetwork`) are the exception: they're AWS IoT
  command executions (`helios-net-wifi-set`, `helios-net-wifi-remove`; Helios's `net.wifi.set`
  and `net.wifi.remove`) and return 200 once the device answers, because the passphrase is a
  secret a shadow mustn't hold. AWS keeps executions, so the service seals the passphrase to the
  device's `secrets_key` first (HPKE, RFC 9180: DHKEM(P-256, HKDF-SHA256), HKDF-SHA256,
  AES-128-GCM; `info` `helios secret v1 <thing>`, AAD `wifi.passphrase <ssid>`): AWS holds only
  ciphertext, and the service never stores or logs the plaintext. If the device doesn't answer in
  time the call fails with `DeviceUnreachable` and nothing is changed. Both are idempotent (a network is identified by its SSID). The SSID goes
  in the body or the query string, never the path, since it can hold any character.
  `WifiPassphrase` is `@sensitive`. `ListWifiNetworks` reads the `net` shadow and never returns
  passphrases.
- `GetDeviceLocation` reads the `gps` shadow (LLD 10): the current fix (or the last one while
  there's none), receivers and satellites. **It returns the device's exact position**, which
  the device reports by design, to anyone allowed to call the Control API; implementations
  mustn't log positions.
- `GetDeviceUplinks` reads the `net` and `stream` shadows (LLD 3): each interface, its public
  IPv4 check, and whether each SRTLA bond has it bonded or in standby. Public addresses are
  personal data: returned only with `?includePublicAddresses=true`, never logged.
  `sharesPublicAddressWith` (interface names) is always returned.
- Control API unions (`Source`, `Input`, `BitrateSetting`) are objects with one member, for
  example `{"rtmp": {"key": "ingest"}}`; `{"profileDefault": {}}` clears a bitrate override.
- `DestinationUrl` is an SRT or SRTLA URL only (`srt://host:port?streamid=…&latency=…&passphrase=…`,
  latency in milliseconds); its documentation lists every rule, which the service and the
  device both enforce.
- `Pin` is `@sensitive`, so generated code redacts it from `toString` and logs.

## Building

```sh
smithy build        # needs the Smithy CLI (1.75.0); Maven dependencies come from smithy-build.json
python3 scripts/check_challenge_vectors.py test-vectors/challenge-*.json   # needs `cryptography`
python3 scripts/check_command_vectors.py test-vectors/*-commands-v*.json
```

The Smithy CLI version is pinned in `.github/workflows/ci.yml` (`SMITHY_VERSION`) and must match
the dependency versions in `smithy-build.json`. Bump them together.

The outputs go to `build/smithy/<projection>/openapi/`:

- `device-api`: OpenAPI 3.1 for `HeliosBootstrap`
- `admin-api`: OpenAPI 3.1 for `HeliosBootstrapAdmin`

The schemas in the OpenAPI output are JSON Schema 2020-12. The `helios` Rust client checks its
hand-written `serde` types against them and against the protocol-test bodies in the model.

## How the other repositories use this one

Both include this repository as a **git submodule pinned to a tagged release**, so a contract
change reaches each side only when that repository bumps the submodule.

- **helios-cloud** generates Java types from the model (Smithy Java type code generation, Java 25)
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

## CI and releases

`.github/workflows/ci.yml` runs on every pull request, on pushes to `main`, and on version tags:

- **Smithy build:** installs the pinned Smithy CLI (checking its published SHA-256), runs
  `smithy build`, which fails on any validation error, and uploads the OpenAPI files as the
  `openapi` artifact.
- **Challenge test vectors:** runs `check_challenge_vectors.py` on the challenge vectors and
  `check_command_vectors.py` on the command vectors.
- **Release:** pushing a tag `vX.Y.Z` (once both jobs pass) creates a GitHub release with the
  OpenAPI files and the test vectors attached.

`smithy build` checks that the protocol tests in the model are well-formed, but it doesn't run
them. They are run by the consumers: `helios-cloud` against its Java implementation, and
`helios` against its Rust types.

## Versioning

- The API version is in the path (`/v1`). Within v1, changes may only add things: new optional
  members, new operations, new enum values. Clients ignore unknown members and must cope with
  unknown enum values.
- Each tag on this repository is a release that `helios` and `helios-cloud` can pin.

## To do

- [x] Fix any validator findings from the first CI run of `smithy build`.
- [x] CI: run `smithy build`, check the challenge vectors, and attach the OpenAPI outputs to
      each tagged release.
- [ ] Add the MQTT message shapes from LLD 2.

## License

[CC0 1.0 Universal](LICENSE).
