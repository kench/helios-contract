# AGENTS.md

helios-contract is the Smithy model of the Helios APIs (`restJson1`): the device service
`HeliosBootstrap` (no auth: Bootstrap, AnswerChallenge), the admin service
`HeliosBootstrapAdmin` (SigV4: RegisterDevice, GetDevice, SetDeviceStatus, DeleteDevice...),
and the control service `HeliosControl` (SigV4, namespace `tv.kenley.helios.control`:
devices, inputs, profiles and streams for operators and agents; HLD section 7.3), plus
challenge test vectors. The design is the Notion page "Helios - Bootstrap API"; current status in
"Helios - Project Status and Handoff". `README.md` has the layout, wire format and release
process.

## Who uses it

`helios` (Rust, hand-written types tested against the OpenAPI output, protocol tests and
vectors) and `helios-cloud` (Java 25 types generated with Smithy Java) include this repository
as a git submodule pinned to a release tag. Both pin `v0.2.0`. A change reaches them only when
they bump the submodule.

## Check your work

```sh
smithy build                     # Smithy CLI 1.75.0 (pinned in ci.yml); fails on any validation error
python3 scripts/check_challenge_vectors.py test-vectors/*.json   # needs `cryptography`
```

## Rules

- Within `/v1` changes may only add things (optional members, operations, enum values). Anything
  else is a breaking change: `!` in the Conventional Commits title and a new major path version.
- Conventional Commits for commits and PR titles; squash merges. CI is required on `main`.
- Releases are tags `vX.Y.Z` on `main`; CI attaches the OpenAPI files and test vectors. The owner
  pushes tags, or an agent the owner has OK'd for that release: it tags the release PR's merge
  commit on `origin/main` once CI passed there, pushes only that tag, never moves one, and
  watches the release.
- `test-vectors/` use a published test key; never put a real device key in this repository.
- Control API rules (owner, 2026-11-21): destinations are SRT or SRTLA URLs only; the cloud never
  sends ffmpeg arguments or pipelines; profiles and streams are defined on the device; changes go
  through the `stream` shadow's desired state.
