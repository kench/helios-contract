$version: "2"

namespace tv.kenley.helios.contract

// Shapes shared by the device API (bootstrap.smithy) and the admin API (admin.smithy).

/// MAC address of a built-in network adapter: lowercase hex, colon-separated.
@pattern("^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
string MacAddress

/// Network interface name (Linux limits names to 15 characters).
@length(min: 1, max: 15)
@pattern("^[^/\\s]+$")
string InterfaceName

/// AWS IoT thing name. Also used as the MQTT client ID.
///
/// Any valid AWS IoT thing name is accepted. The strongly recommended format is
/// "t-" followed by a ULID (for example "t-01JD5VY2K7M9Q4R6T8V0X2Z4B6"),
/// matching device and challenge IDs. It is not enforced.
@length(min: 1, max: 128)
@pattern("^[a-zA-Z0-9:_-]+$")
string ThingName

/// Service-generated device ID: "d-" followed by a ULID.
@pattern("^d-[0-9A-HJKMNP-TV-Z]{26}$")
string DeviceId

/// PKCS#11 token or object label (at most 32 bytes).
@length(min: 1, max: 32)
string Pkcs11Label

/// Token user PIN. Never logged, and never returned by the admin API.
@sensitive
@length(min: 4, max: 255)
string Pin

/// Timestamp serialized as an RFC 3339 string in UTC.
@timestampFormat("date-time")
timestamp DateTime

enum AdapterKind {
    ETHERNET = "ethernet"
    WIFI = "wifi"
}

/// A built-in network adapter, identified by its permanent MAC address.
structure Adapter {
    @required
    interfaceName: InterfaceName

    @required
    kind: AdapterKind

    @required
    mac: MacAddress
}

@length(min: 1, max: 8)
list AdapterList {
    member: Adapter
}

@length(min: 1, max: 8)
@uniqueItems
list MacAddressList {
    member: MacAddress
}

/// Labels Helios uses to find its token and keys.
structure TokenLabels {
    @required
    tokenLabel: Pkcs11Label

    @required
    keyLabel: Pkcs11Label

    /// PIN-less key used to answer bootstrap challenges, if the device has one.
    challengeKeyLabel: Pkcs11Label
}

@length(min: 1, max: 253)
@pattern("^[a-z0-9.-]+$")
string HostName

@pattern("^[a-z]{2}(-[a-z]+)+-[0-9]+$")
string AwsRegion

@length(min: 1, max: 128)
@pattern("^[\\w=,@-]+$")
string RoleAlias

/// AWS settings for the device. If present, they fill in or must match the
/// device's local [aws] configuration.
structure AwsSettings {
    @required
    region: AwsRegion

    @required
    iotEndpoint: HostName

    @required
    credentialsEndpoint: HostName

    @required
    roleAlias: RoleAlias
}

/// Too many requests. Wait at least retryAfterSeconds before retrying.
@error("client")
@httpError(429)
@retryable(throttling: true)
structure RateLimited {
    message: String

    @httpHeader("Retry-After")
    retryAfterSeconds: Integer
}

/// Unexpected service error. Safe to retry with backoff.
@error("server")
@httpError(500)
@retryable
structure InternalError {
    message: String
}
