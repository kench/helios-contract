$version: "2"

namespace tv.kenley.helios.contract

use aws.auth#sigv4
use aws.protocols#restJson1
use smithy.framework#ValidationException

/// Admin API for registering and managing devices in the bootstrap service.
/// Used by provisioning scripts and operators, never by devices.
/// Authenticated with AWS IAM (SigV4, API Gateway).
@restJson1
@sigv4(name: "execute-api")
@title("Helios Bootstrap Admin API")
service HeliosBootstrapAdmin {
    version: "2026-11-18"
    resources: [
        Device
    ]
    errors: [
        ValidationException
        RateLimited
        InternalError
    ]
}

resource Device {
    identifiers: { deviceId: DeviceId }
    create: RegisterDevice
    read: GetDevice
    update: UpdateDevice
    delete: DeleteDevice
    list: ListDevices
    operations: [
        SetDeviceStatus
        SetDevicePin
        PutChallengeKey
        DeleteChallengeKey
    ]
}

/// Registers a device. Each MAC address and the thing name can belong to only one record.
@http(method: "POST", uri: "/v1/admin/devices", code: 201)
operation RegisterDevice {
    input := {
        @required
        thingName: ThingName

        @required
        role: DeviceRole

        /// Permanent MACs of the device's built-in adapters.
        @required
        macs: MacAddressList

        /// The token's current user PIN. Read from the provisioning session,
        /// never typed on a command line.
        @required
        pin: Pin

        @required
        token: TokenLabels

        challenge: ChallengeSettings

        /// Leave out to use the service's default settings for its environment.
        aws: AwsSettings
    }

    output := {
        @required
        device: DeviceDescription
    }

    errors: [
        RegistrationConflict
        InvalidChallengeKey
    ]
}

/// Gets a device record. The PIN is never returned.
@readonly
@http(method: "GET", uri: "/v1/admin/devices/{deviceId}", code: 200)
operation GetDevice {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {
        @required
        device: DeviceDescription
    }

    errors: [
        DeviceNotFound
    ]
}

/// Changes a device record. Members that are left out are unchanged.
/// Status, PIN and challenge key have their own operations.
@http(method: "PATCH", uri: "/v1/admin/devices/{deviceId}", code: 200)
operation UpdateDevice {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        thingName: ThingName

        role: DeviceRole

        macs: MacAddressList

        token: TokenLabels

        aws: AwsSettings

        /// true requires a registered challenge key.
        challengeRequired: Boolean
    }

    output := {
        @required
        device: DeviceDescription
    }

    errors: [
        DeviceNotFound
        RegistrationConflict
        ChallengeKeyNotRegistered
    ]
}

/// Deletes a device record and frees its MACs. Only allowed while the device is disabled.
@idempotent
@http(method: "DELETE", uri: "/v1/admin/devices/{deviceId}", code: 204)
operation DeleteDevice {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {}

    errors: [
        DeviceNotFound
        DeviceNotDisabled
    ]
}

/// Lists device records, optionally filtered by MAC address or thing name.
@readonly
@paginated(inputToken: "nextToken", outputToken: "nextToken", pageSize: "maxResults", items: "devices")
@http(method: "GET", uri: "/v1/admin/devices", code: 200)
operation ListDevices {
    input := {
        @httpQuery("mac")
        mac: MacAddress

        @httpQuery("thingName")
        thingName: ThingName

        @httpQuery("nextToken")
        nextToken: String

        @httpQuery("maxResults")
        @range(min: 1, max: 100)
        maxResults: Integer
    }

    output := {
        @required
        devices: DeviceDescriptionList

        nextToken: String
    }
}

/// Enables or disables a device. Disabling is step 1 of the lost-device runbook:
/// from then on, Bootstrap returns DeviceDisabled for it.
@idempotent
@http(method: "PUT", uri: "/v1/admin/devices/{deviceId}/status", code: 200)
operation SetDeviceStatus {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        status: DeviceStatus

        /// Why the device was disabled (for example "lost 2026-11-18").
        reason: StatusReason
    }

    output := {
        @required
        device: DeviceDescription
    }

    errors: [
        DeviceNotFound
    ]
}

/// Replaces the stored PIN. Change the PIN on the device's token first, then
/// call this. If the order is wrong, the device spends one PIN try and stops.
@idempotent
@http(method: "PUT", uri: "/v1/admin/devices/{deviceId}/pin", code: 204)
operation SetDevicePin {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        pin: Pin
    }

    output := {}

    errors: [
        DeviceNotFound
    ]
}

/// Registers or replaces the device's challenge public key.
@idempotent
@http(method: "PUT", uri: "/v1/admin/devices/{deviceId}/challenge-key", code: 200)
operation PutChallengeKey {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        /// P-256 SubjectPublicKeyInfo in PEM, as written by `helios provision challenge-key`.
        @required
        publicKeyPem: PublicKeyPem
    }

    output := {
        @required
        challenge: ChallengeKeyDescription
    }

    errors: [
        DeviceNotFound
        InvalidChallengeKey
    ]
}

/// Removes the challenge key. Fails while the device requires a challenge.
@idempotent
@http(method: "DELETE", uri: "/v1/admin/devices/{deviceId}/challenge-key", code: 204)
operation DeleteChallengeKey {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {}

    errors: [
        DeviceNotFound
        ChallengeKeyRequired
    ]
}

enum DeviceRole {
    SCANNER = "scanner"
    TRANSCODER = "transcoder"
}

enum DeviceStatus {
    ACTIVE = "active"
    DISABLED = "disabled"
}

@length(min: 1, max: 256)
string StatusReason

@length(min: 1, max: 4096)
string PublicKeyPem

/// SHA-256 of the DER SubjectPublicKeyInfo, as lowercase hex.
@pattern("^[0-9a-f]{64}$")
string KeyFingerprint

@length(min: 1, max: 45)
string IpAddress

structure ChallengeSettings {
    /// When true, Bootstrap answers with a challenge before returning the identity.
    /// Requires publicKeyPem.
    required: Boolean = false

    publicKeyPem: PublicKeyPem
}

structure ChallengeKeyDescription {
    @required
    required: Boolean

    publicKeyPem: PublicKeyPem

    keyFingerprint: KeyFingerprint

    registeredAt: DateTime
}

/// Result of the device's most recent Bootstrap or AnswerChallenge call.
enum LookupResult {
    IDENTITY_RETURNED = "identity_returned"
    CHALLENGE_ISSUED = "challenge_issued"
    CHALLENGE_FAILED = "challenge_failed"
    CHALLENGE_EXPIRED = "challenge_expired"
    CHALLENGE_UNSUPPORTED = "challenge_unsupported"
    DEVICE_DISABLED = "device_disabled"
    AMBIGUOUS_DEVICE = "ambiguous_device"
}

structure LastSeen {
    @required
    at: DateTime

    @required
    result: LookupResult

    sourceIp: IpAddress

    heliosVersion: HeliosVersion

    hardwareModel: HardwareModel
}

/// A device record as returned by the admin API. Never includes the PIN.
structure DeviceDescription {
    @required
    deviceId: DeviceId

    @required
    thingName: ThingName

    @required
    role: DeviceRole

    @required
    status: DeviceStatus

    disabledAt: DateTime

    disabledReason: StatusReason

    @required
    macs: MacAddressList

    @required
    token: TokenLabels

    @required
    challenge: ChallengeKeyDescription

    aws: AwsSettings

    lastSeen: LastSeen

    @required
    createdAt: DateTime

    @required
    updatedAt: DateTime
}

list DeviceDescriptionList {
    member: DeviceDescription
}

/// No device record has this ID.
@error("client")
@httpError(404)
structure DeviceNotFound {
    message: String
}

/// A MAC address or the thing name already belongs to another device record.
@error("client")
@httpError(409)
structure RegistrationConflict {
    message: String

    conflictingMacs: MacAddressList

    conflictingThingName: ThingName
}

/// Devices can only be deleted while disabled.
@error("client")
@httpError(409)
structure DeviceNotDisabled {
    message: String
}

/// The challenge key can't be removed while the device requires a challenge.
@error("client")
@httpError(409)
structure ChallengeKeyRequired {
    message: String
}

/// challengeRequired can only be true once a challenge key is registered.
@error("client")
@httpError(409)
structure ChallengeKeyNotRegistered {
    message: String
}

/// The public key isn't a valid P-256 SubjectPublicKeyInfo in PEM.
@error("client")
@httpError(400)
structure InvalidChallengeKey {
    message: String
}
