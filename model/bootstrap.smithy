$version: "2"

namespace tv.kenley.helios.contract

use aws.protocols#restJson1
use smithy.framework#ValidationException
use smithy.test#httpRequestTests
use smithy.test#httpResponseTests

/// Device-facing Helios bootstrap API. Helios calls it at startup, before it can
/// use its token, to get the token PIN and its device identity.
///
/// There is no client authentication: before it has the PIN, a device has no
/// credential it could present. Optional proof that the token is present comes
/// from the challenge (AnswerChallenge).
@restJson1
@title("Helios Bootstrap API")
service HeliosBootstrap {
    version: "2026-11-18"
    operations: [
        Bootstrap
        AnswerChallenge
    ]
    errors: [
        ValidationException
        RateLimited
        InternalError
    ]
}

/// First request at every Helios start. Returns the device identity, or a
/// challenge if the device record requires one.
@http(method: "POST", uri: "/v1/device/bootstrap", code: 200)
@httpRequestTests([
    {
        id: "BootstrapRequestWithChallengeCapability"
        documentation: "A relay with Ethernet and Wi-Fi that can answer challenges."
        protocol: restJson1
        method: "POST"
        uri: "/v1/device/bootstrap"
        headers: {
            "Content-Type": "application/json"
        }
        body: """
            {
                "adapters": [
                    {"interfaceName": "eth0", "kind": "ethernet", "mac": "2c:cf:67:00:00:01"},
                    {"interfaceName": "wlan0", "kind": "wifi", "mac": "2c:cf:67:00:00:02"}
                ],
                "heliosVersion": "0.1.0",
                "hardwareModel": "Raspberry Pi 5 Model B Rev 1.0",
                "capabilities": ["token-challenge"]
            }"""
        bodyMediaType: "application/json"
        params: {
            adapters: [
                { interfaceName: "eth0", kind: "ethernet", mac: "2c:cf:67:00:00:01" }
                { interfaceName: "wlan0", kind: "wifi", mac: "2c:cf:67:00:00:02" }
            ]
            heliosVersion: "0.1.0"
            hardwareModel: "Raspberry Pi 5 Model B Rev 1.0"
            capabilities: ["token-challenge"]
        }
    }
    {
        id: "BootstrapRequestMinimal"
        documentation: "A scanner with one built-in Ethernet adapter and no challenge key."
        protocol: restJson1
        method: "POST"
        uri: "/v1/device/bootstrap"
        headers: {
            "Content-Type": "application/json"
        }
        body: """
            {
                "adapters": [
                    {"interfaceName": "eth0", "kind": "ethernet", "mac": "00:11:22:33:44:55"}
                ],
                "heliosVersion": "0.1.0"
            }"""
        bodyMediaType: "application/json"
        params: {
            adapters: [
                { interfaceName: "eth0", kind: "ethernet", mac: "00:11:22:33:44:55" }
            ]
            heliosVersion: "0.1.0"
        }
    }
])
@httpResponseTests([
    {
        id: "BootstrapReturnsIdentity"
        protocol: restJson1
        code: 200
        headers: {
            "Content-Type": "application/json"
        }
        body: """
            {
                "identity": {
                    "deviceId": "d-01JD5VZ6R1H8P3S0W2Y4A6C8E0",
                    "thingName": "t-01JD5VY2K7M9Q4R6T8V0X2Z4B6",
                    "pin": "123456",
                    "token": {
                        "tokenLabel": "helios",
                        "keyLabel": "device-key",
                        "challengeKeyLabel": "challenge-key"
                    },
                    "aws": {
                        "region": "us-west-2",
                        "iotEndpoint": "example-ats.iot.us-west-2.amazonaws.com",
                        "credentialsEndpoint": "example.credentials.iot.us-west-2.amazonaws.com",
                        "roleAlias": "helios-device-role-alias"
                    }
                }
            }"""
        bodyMediaType: "application/json"
        params: {
            result: {
                identity: {
                    deviceId: "d-01JD5VZ6R1H8P3S0W2Y4A6C8E0"
                    thingName: "t-01JD5VY2K7M9Q4R6T8V0X2Z4B6"
                    pin: "123456"
                    token: {
                        tokenLabel: "helios"
                        keyLabel: "device-key"
                        challengeKeyLabel: "challenge-key"
                    }
                    aws: {
                        region: "us-west-2"
                        iotEndpoint: "example-ats.iot.us-west-2.amazonaws.com"
                        credentialsEndpoint: "example.credentials.iot.us-west-2.amazonaws.com"
                        roleAlias: "helios-device-role-alias"
                    }
                }
            }
        }
    }
    {
        id: "BootstrapReturnsChallenge"
        protocol: restJson1
        code: 200
        headers: {
            "Content-Type": "application/json"
        }
        body: """
            {
                "challenge": {
                    "challengeId": "c-01JD5W3Q8T6M2K4X9B0N7C1D2E",
                    "nonce": "dGVzdC1ub25jZS0wMTIzNDU2Nzg5YWJjZGVmMDEyMzQ=",
                    "alg": "ecdsa-p256-sha256",
                    "expiresAt": "2026-11-19T05:31:00Z"
                }
            }"""
        bodyMediaType: "application/json"
        params: {
            result: {
                challenge: {
                    challengeId: "c-01JD5W3Q8T6M2K4X9B0N7C1D2E"
                    nonce: "test-nonce-0123456789abcdef01234"
                    alg: "ecdsa-p256-sha256"
                    expiresAt: 1795066260
                }
            }
        }
    }
])
operation Bootstrap {
    input := {
        /// The device's built-in adapters, sorted by interface name.
        @required
        adapters: AdapterList

        @required
        heliosVersion: HeliosVersion

        /// From /proc/device-tree/model, if present. Used only for logs and audit.
        hardwareModel: HardwareModel

        /// "token-challenge" when Helios has a challenge key configured and found.
        capabilities: CapabilityList
    }

    output := {
        @required
        @httpPayload
        result: BootstrapResult
    }

    errors: [
        UnknownDevice
        AmbiguousDevice
        DeviceDisabled
        ChallengeUnsupported
    ]
}

/// Answers a challenge returned by Bootstrap.
///
/// The signed message is the UTF-8 bytes of
/// "helios-bootstrap-v1\n" + challengeId + "\n" + nonce (base64, exactly as
/// received) + "\n" + the request's MACs sorted ascending and joined with ",".
/// It is hashed with SHA-256 and signed with ECDSA P-256. See the challenge
/// test vectors in test-vectors/.
@http(method: "POST", uri: "/v1/device/bootstrap/challenge", code: 200)
@httpRequestTests([
    {
        id: "AnswerChallengeRequest"
        protocol: restJson1
        method: "POST"
        uri: "/v1/device/bootstrap/challenge"
        headers: {
            "Content-Type": "application/json"
        }
        body: """
            {
                "challengeId": "c-01JD5W3Q8T6M2K4X9B0N7C1D2E",
                "signature": "dGVzdC1zaWduYXR1cmU=",
                "adapters": [
                    {"interfaceName": "eth0", "kind": "ethernet", "mac": "2c:cf:67:00:00:01"}
                ]
            }"""
        bodyMediaType: "application/json"
        params: {
            challengeId: "c-01JD5W3Q8T6M2K4X9B0N7C1D2E"
            signature: "test-signature"
            adapters: [
                { interfaceName: "eth0", kind: "ethernet", mac: "2c:cf:67:00:00:01" }
            ]
        }
    }
])
operation AnswerChallenge {
    input := {
        @required
        challengeId: ChallengeId

        /// DER-encoded ECDSA P-256 signature over the challenge message.
        @required
        signature: ChallengeSignature

        /// The same adapters as in the Bootstrap request.
        @required
        adapters: AdapterList
    }

    output := {
        @required
        @httpPayload
        identity: DeviceIdentity
    }

    errors: [
        ChallengeExpired
        ChallengeFailed
        DeviceDisabled
    ]
}

/// Either a challenge to answer first, or the device identity.
union BootstrapResult {
    /// Proof that the token is present is required first. Answer it with AnswerChallenge.
    challenge: Challenge

    /// The device identity and token PIN.
    identity: DeviceIdentity
}

structure Challenge {
    @required
    challengeId: ChallengeId

    @required
    nonce: Nonce

    @required
    alg: SignatureAlgorithm

    /// The challenge can be answered once, until this time.
    @required
    expiresAt: DateTime
}

/// deviceId identifies the Device resource managed through the admin API.
@references([{ resource: Device }])
structure DeviceIdentity {
    @required
    deviceId: DeviceId

    @required
    thingName: ThingName

    @required
    pin: Pin

    @required
    token: TokenLabels

    aws: AwsSettings
}

/// Service-generated challenge ID: "c-" followed by a ULID.
@pattern("^c-[0-9A-HJKMNP-TV-Z]{26}$")
string ChallengeId

/// 32 random bytes.
@length(min: 32, max: 32)
blob Nonce

/// DER-encoded ECDSA P-256 signature (at most 72 bytes).
@length(min: 8, max: 72)
blob ChallengeSignature

enum SignatureAlgorithm {
    ECDSA_P256_SHA256 = "ecdsa-p256-sha256"
}

enum Capability {
    TOKEN_CHALLENGE = "token-challenge"
}

@length(max: 8)
@uniqueItems
list CapabilityList {
    member: Capability
}

@length(min: 1, max: 64)
string HeliosVersion

@length(min: 1, max: 128)
string HardwareModel

/// No registered device has any of these MAC addresses.
@error("client")
@httpError(404)
structure UnknownDevice {
    message: String
}

/// The MAC addresses belong to more than one device record.
@error("client")
@httpError(409)
structure AmbiguousDevice {
    message: String
}

/// The device record exists but is disabled (for example, the device was lost).
@error("client")
@httpError(403)
@httpResponseTests([
    {
        id: "DeviceDisabledError"
        protocol: restJson1
        code: 403
        headers: {
            "Content-Type": "application/json"
            "X-Amzn-Errortype": "DeviceDisabled"
        }
        body: "{\"message\":\"Device is disabled.\"}"
        bodyMediaType: "application/json"
        params: {
            message: "Device is disabled."
        }
    }
])
structure DeviceDisabled {
    message: String
}

/// The device record requires a challenge, but the request didn't list "token-challenge".
@error("client")
@httpError(403)
structure ChallengeUnsupported {
    message: String
}

/// The signature didn't verify, or the adapters don't match the original request.
@error("client")
@httpError(403)
structure ChallengeFailed {
    message: String
}

/// The challenge expired or was already used. Start again with Bootstrap.
@error("client")
@httpError(403)
structure ChallengeExpired {
    message: String
}
