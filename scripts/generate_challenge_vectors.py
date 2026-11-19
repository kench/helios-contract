#!/usr/bin/env python3
"""Generates test-vectors/challenge-v1.json for the bootstrap challenge.

The vectors let both sides test the challenge independently:
  - helios (Rust): builds the exact message bytes and SHA-256 digest, converts a
    raw r||s signature to DER, and checks its own signatures verify.
  - helios-cloud (Java): rebuilds the message from a request and verifies the
    DER signature with the registered public key, rejecting the invalid cases.

The key pair is a TEST KEY ONLY. It is committed on purpose and must never be
registered for a real device.

ECDSA signatures are randomized, so re-running this script produces a new key
and new signatures. The message and digest values stay the same.

Usage: python3 scripts/generate_challenge_vectors.py > test-vectors/challenge-v1.json
Requires: the `cryptography` package.
"""

import base64
import hashlib
import json
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    Prehashed,
    decode_dss_signature,
)

PREFIX = "helios-bootstrap-v1"


def build_message(challenge_id: str, nonce_b64: str, macs: list[str]) -> bytes:
    """The exact bytes that are hashed and signed (no trailing newline)."""
    return "\n".join([PREFIX, challenge_id, nonce_b64, ",".join(sorted(macs))]).encode("utf-8")


def sign(key: ec.EllipticCurvePrivateKey, digest: bytes) -> bytes:
    return key.sign(digest, ec.ECDSA(Prehashed(hashes.SHA256())))


def verifies(public_key: ec.EllipticCurvePublicKey, signature: bytes, message: bytes) -> bool:
    try:
        public_key.verify(signature, message, ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False


def main() -> None:
    key = ec.generate_private_key(ec.SECP256R1())
    public_key = key.public_key()
    spki_der = public_key.public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )

    challenge_id = "c-01JD5W3Q8T6M2K4X9B0N7C1D2E"
    nonce = bytes(range(32))
    nonce_b64 = base64.b64encode(nonce).decode("ascii")
    # Request order (sorted by interface name), deliberately not MAC order, so the
    # sort inside the message is exercised.
    adapters = [
        {"interfaceName": "eth0", "kind": "ethernet", "mac": "dc:a6:32:00:00:09"},
        {"interfaceName": "wlan0", "kind": "wifi", "mac": "2c:cf:67:00:00:02"},
    ]
    macs = [a["mac"] for a in adapters]

    message = build_message(challenge_id, nonce_b64, macs)
    digest = hashlib.sha256(message).digest()
    signature = sign(key, digest)
    r, s = decode_dss_signature(signature)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    assert verifies(public_key, signature, message)

    def case(case_id, description, macs_for_check, nonce_for_check, valid):
        check = build_message(challenge_id, nonce_for_check, macs_for_check)
        assert verifies(public_key, signature, check) == valid, case_id
        return {
            "id": case_id,
            "description": description,
            "macs": macs_for_check,
            "nonce": nonce_for_check,
            "message": check.decode("utf-8"),
            "messageSha256Hex": hashlib.sha256(check).hexdigest(),
            "signatureVerifies": valid,
        }

    vectors = {
        "version": 1,
        "description": "Bootstrap challenge test vectors (see the Bootstrap API page, section 3.2). "
        "TEST KEY ONLY: never register this key for a real device.",
        "algorithm": "ecdsa-p256-sha256",
        "messageFormat": "helios-bootstrap-v1\\n<challengeId>\\n<nonce base64 as received>\\n"
        "<MACs sorted ascending, joined with ','>",
        "testKey": {
            "privateKeyPkcs8Pem": key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ).decode("ascii"),
            "publicKeySpkiPem": public_key.public_bytes(
                serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
            ).decode("ascii"),
            "publicKeyFingerprint": hashlib.sha256(spki_der).hexdigest(),
        },
        "challenge": {
            "challengeId": challenge_id,
            "nonce": nonce_b64,
            "alg": "ecdsa-p256-sha256",
        },
        "request": {"adapters": adapters},
        "signature": {
            "derBase64": base64.b64encode(signature).decode("ascii"),
            "rawRsHex": raw.hex(),
        },
        "cases": [
            case("valid", "Message built from the original request. Must verify.", macs, nonce_b64, True),
            case(
                "different-macs",
                "A different MAC set (one MAC changed). Must not verify.",
                ["dc:a6:32:00:00:09", "2c:cf:67:00:00:03"],
                nonce_b64,
                False,
            ),
            case(
                "different-nonce",
                "A different nonce. Must not verify.",
                macs,
                base64.b64encode(bytes(range(1, 33))).decode("ascii"),
                False,
            ),
        ],
    }

    json.dump(vectors, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
