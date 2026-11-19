#!/usr/bin/env python3
"""Checks a challenge test-vector file for internal consistency.

Run in CI on every change, so a hand edit or a bad regeneration can't publish
vectors that disagree with themselves or with the message format.

Checks:
  - the test private key matches the test public key, and the fingerprint is
    SHA-256 of the DER SubjectPublicKeyInfo,
  - the raw r||s signature re-encodes to the DER signature,
  - each case's message is rebuilt exactly from the challenge fields (the
    'valid' case from the request's adapters),
  - each case's SHA-256 digest matches its message,
  - the signature verifies for exactly the cases that say it should.

Usage: python3 scripts/check_challenge_vectors.py test-vectors/challenge-v1.json
Requires: the `cryptography` package.
"""

import base64
import hashlib
import json
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

PREFIX = "helios-bootstrap-v1"


def build_message(challenge_id: str, nonce_b64: str, macs: list[str]) -> str:
    return "\n".join([PREFIX, challenge_id, nonce_b64, ",".join(sorted(macs))])


def check(path: str) -> list[str]:
    errors: list[str] = []
    with open(path, encoding="utf-8") as f:
        vectors = json.load(f)

    key = vectors["testKey"]
    private_key = serialization.load_pem_private_key(
        key["privateKeyPkcs8Pem"].encode("ascii"), password=None
    )
    public_key = serialization.load_pem_public_key(key["publicKeySpkiPem"].encode("ascii"))
    if not isinstance(public_key, ec.EllipticCurvePublicKey) or not isinstance(
        public_key.curve, ec.SECP256R1
    ):
        errors.append("test public key is not a P-256 key")
        return errors

    spki_der = public_key.public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    derived_spki = private_key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    if derived_spki != spki_der:
        errors.append("test private key does not match the test public key")
    if hashlib.sha256(spki_der).hexdigest() != key["publicKeyFingerprint"]:
        errors.append("publicKeyFingerprint is not SHA-256 of the DER SubjectPublicKeyInfo")

    signature = base64.b64decode(vectors["signature"]["derBase64"], validate=True)
    raw = bytes.fromhex(vectors["signature"]["rawRsHex"])
    if len(raw) != 64:
        errors.append("rawRsHex is not 64 bytes")
    elif encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")) != signature:
        errors.append("rawRsHex does not re-encode to derBase64")

    challenge = vectors["challenge"]
    request_macs = [a["mac"] for a in vectors["request"]["adapters"]]
    if len(base64.b64decode(challenge["nonce"], validate=True)) != 32:
        errors.append("challenge nonce is not 32 bytes")

    cases = vectors["cases"]
    if not any(c["id"] == "valid" and c["signatureVerifies"] for c in cases):
        errors.append("no valid case")

    for case in cases:
        case_id = case["id"]
        expected = build_message(challenge["challengeId"], case["nonce"], case["macs"])
        if case["message"] != expected:
            errors.append(f"{case_id}: message does not match the message format")
        if case_id == "valid" and (
            case["nonce"] != challenge["nonce"] or sorted(case["macs"]) != sorted(request_macs)
        ):
            errors.append("valid: does not use the challenge nonce and the request's MACs")
        message = case["message"].encode("utf-8")
        if hashlib.sha256(message).hexdigest() != case["messageSha256Hex"]:
            errors.append(f"{case_id}: messageSha256Hex does not match the message")
        try:
            public_key.verify(signature, message, ec.ECDSA(hashes.SHA256()))
            verifies = True
        except InvalidSignature:
            verifies = False
        if verifies != case["signatureVerifies"]:
            errors.append(f"{case_id}: signature verifies={verifies}, expected {case['signatureVerifies']}")

    return errors


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    failed = False
    for path in sys.argv[1:]:
        errors = check(path)
        for error in errors:
            print(f"{path}: {error}", file=sys.stderr)
        print(f"{path}: {'FAILED' if errors else 'ok'}")
        failed = failed or bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
