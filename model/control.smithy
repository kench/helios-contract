$version: "2"

namespace tv.kenley.helios.control

use aws.auth#sigv4
use aws.protocols#restJson1
use smithy.framework#ValidationException
use smithy.test#httpRequestTests
use tv.kenley.helios.contract#DateTime
use tv.kenley.helios.contract#DeviceId
use tv.kenley.helios.contract#DeviceNotFound
use tv.kenley.helios.contract#DeviceRole
use tv.kenley.helios.contract#DeviceStatus
use tv.kenley.helios.contract#InternalError
use tv.kenley.helios.contract#RateLimited
use tv.kenley.helios.contract#ThingName

/// Control API for operators and agents: see devices and their streams, and start, stop and
/// adjust the streams (HLD section 7.3). Served by the bootstrap service's REST API under
/// /v1/control. Authenticated with AWS IAM (SigV4, API Gateway): callers assume helios-operator.
///
/// Changes are written to the device's `stream` shadow as desired state and return 202: the
/// device applies them when it can (also after being offline) and reports the result, which
/// GetStream shows. The device is the final judge of every value: it refuses sources, profiles
/// and destinations it can't use, and reports why. The cloud never sends ffmpeg arguments or
/// pipelines; profiles and the streams themselves are defined on the device.
@restJson1
@sigv4(name: "execute-api")
@title("Helios Control API")
service HeliosControl {
    version: "2026-11-21"
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
    read: GetDevice
    list: ListDevices
    resources: [
        Stream
    ]
    operations: [
        ListInputs
        ListProfiles
        GetDeviceLocation
        ListWifiNetworks
        SetWifiNetwork
        DeleteWifiNetwork
    ]
}

resource Stream {
    identifiers: { deviceId: DeviceId, streamId: StreamId }
    read: GetStream
    list: ListStreams
    update: UpdateStream
    operations: [
        StartStream
        StopStream
        SetStreamDestination
        GetStreamStatus
    ]
}

// --- Devices -------------------------------------------------------------------------------

/// Lists the devices in the bootstrap service, with whether each is connected now.
@readonly
@paginated(inputToken: "nextToken", outputToken: "nextToken", pageSize: "maxResults", items: "devices")
@http(method: "GET", uri: "/v1/control/devices", code: 200)
operation ListDevices {
    input := {
        @httpQuery("nextToken")
        nextToken: String

        @httpQuery("maxResults")
        @range(min: 1, max: 100)
        maxResults: Integer
    }

    output := {
        @required
        devices: DeviceSummaryList

        nextToken: String
    }
}

/// Gets one device: its record, connection, Helios version and modules.
@readonly
@http(method: "GET", uri: "/v1/control/devices/{deviceId}", code: 200)
operation GetDevice {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {
        @required
        device: DeviceSummary

        /// Each module's state from the `helios` shadow, by module name.
        modules: ModuleStateMap
    }

    errors: [
        DeviceNotFound
    ]
}

/// Lists what a device can stream from, as it last reported: attached cameras and audio
/// devices, its RTMP ingest keys and the test pattern.
@readonly
@http(method: "GET", uri: "/v1/control/devices/{deviceId}/inputs", code: 200)
operation ListInputs {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {
        @required
        inputs: InputList

        /// When the device last reported them.
        reportedAt: DateTime
    }

    errors: [
        DeviceNotFound
        DeviceStateUnavailable
    ]
}

/// Lists the encoding profiles defined on the device, which a stream can be switched between.
@readonly
@http(method: "GET", uri: "/v1/control/devices/{deviceId}/profiles", code: 200)
operation ListProfiles {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {
        @required
        profiles: ProfileList
    }

    errors: [
        DeviceNotFound
        DeviceStateUnavailable
    ]
}

/// The device's position, as its gps module last reported it (LLD 10): the current fix, or
/// the last one while there's no fix, with the receivers and satellites behind it.
///
/// **This is the device's exact location.** The device reports the full fix by design (the
/// owner's choice), so anyone allowed to call the Control API can read where the device is.
/// Keep positions out of logs, tickets and anything shared.
@readonly
@http(method: "GET", uri: "/v1/control/devices/{deviceId}/location", code: 200)
operation GetDeviceLocation {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {
        /// Whether the device's gps module can reach gpsd.
        @required
        gpsd: GpsdState

        /// The GPS receivers gpsd has open.
        @required
        receivers: GpsReceiverList

        /// The current fix: mode none, with no position, when there isn't one.
        @required
        fix: GpsFix

        /// The last fix the device had, while `fix` is none. It stays until a new fix replaces
        /// it, so its `time` says how old it is.
        lastFix: GpsFix

        /// The satellites behind the fix, from the receiver's last report.
        satellites: GpsSatellites

        /// When the fix's mode last changed (for example, when the fix was lost).
        @required
        since: DateTime

        /// The receiver path set in the device's config, and whether gpsd took it.
        configuredReceiver: GpsConfiguredReceiver

        /// When the device last reported its gps state.
        reportedAt: DateTime
    }

    errors: [
        DeviceNotFound
        DeviceStateUnavailable
    ]
}

enum GpsdState {
    CONNECTED = "connected"

    /// gpsd isn't running or its socket can't be opened; the module retries.
    UNAVAILABLE = "unavailable"
}

enum GpsFixMode {
    NONE = "none"

    /// Latitude and longitude.
    TWO_D = "2d"

    /// With altitude.
    THREE_D = "3d"
}

/// A fix. Every member but `mode` is absent when the mode is none, and any the receiver didn't
/// report is absent too.
structure GpsFix {
    @required
    mode: GpsFixMode

    /// The fix's time, from the satellites (UTC).
    time: DateTime

    /// Degrees north (WGS 84).
    latitude: Double

    /// Degrees east (WGS 84).
    longitude: Double

    /// Altitude above mean sea level, metres (3d fixes).
    altitudeM: Double

    /// Speed over ground, metres per second.
    speedMps: Double

    /// Course over ground, degrees from true north.
    trackDeg: Double

    /// Vertical speed, metres per second (up is positive).
    climbMps: Double

    /// Estimated horizontal error, metres (gpsd's eph, about 95% confidence).
    horizontalErrorM: Double

    /// Estimated vertical error, metres (gpsd's epv).
    verticalErrorM: Double
}

structure GpsSatellites {
    /// Satellites used in the fix.
    used: Integer

    /// Satellites the receiver can see.
    visible: Integer

    /// Horizontal dilution of precision.
    hdop: Double

    /// Position dilution of precision.
    pdop: Double
}

list GpsReceiverList {
    member: GpsReceiver
}

structure GpsReceiver {
    /// The receiver's device path on the device, for example /dev/ttyACM0.
    @required
    path: String

    /// gpsd's driver for it, for example NMEA0183.
    driver: String

    /// Its serial speed, bits per second.
    bps: Integer

    /// Its USB port, for example 1-1.3, when it's on USB.
    usbPort: UsbPort
}

structure GpsConfiguredReceiver {
    /// The path from the device's config (`[modules.gps] device`).
    @required
    path: String

    /// Whether gpsd has it open.
    @required
    added: Boolean

    /// Why gpsd didn't take it.
    error: String
}

// --- Wi-Fi networks -------------------------------------------------------------------------

/// Lists the Wi-Fi networks the device is set to join, as it last reported them (in its `net`
/// shadow). Passphrases are never reported or returned.
@readonly
@http(method: "GET", uri: "/v1/control/devices/{deviceId}/wifi/networks", code: 200)
operation ListWifiNetworks {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {
        @required
        networks: WifiNetworkList

        /// When the device last reported them.
        reportedAt: DateTime
    }

    errors: [
        DeviceNotFound
        DeviceStateUnavailable
    ]
}

/// Adds a Wi-Fi network for the device to join, or replaces the one with the same SSID. An AWS
/// IoT command execution (helios-net-wifi-set, Helios's net.wifi.set), not a shadow change,
/// because the passphrase is a secret a shadow mustn't hold. AWS keeps command executions, so
/// the service first seals the passphrase to the device's key (HPKE, RFC 9180, to the
/// `secrets_key` in its `helios` shadow, bound to the device and the SSID): AWS only ever holds
/// ciphertext, only that device can open it, and the service never stores or logs the
/// plaintext. The device keeps it readable only by root. The device must be online: if it
/// doesn't answer in time, the call fails with DeviceUnreachable and nothing is changed. The
/// device saves the network and applies it to its network configuration (netplan or
/// NetworkManager); its `net` shadow then shows whether the Wi-Fi adapter joined. HLD 7.3,
/// LLD 2 section 7.3, LLD 3 section 10.
@idempotent
@httpRequestTests([
    {
        id: "SetAPersonalWifiNetwork"
        documentation: "The SSID and passphrase are in the body, never the path."
        protocol: restJson1
        method: "PUT"
        uri: "/v1/control/devices/d-01JD5VY2K7M9Q4R6T8V0X2Z4B6/wifi/networks"
        headers: { "Content-Type": "application/json" }
        body: """
            {
              "ssid": "Venue / Media",
              "passphrase": "correct horse battery",
              "hidden": false
            }
            """
        bodyMediaType: "application/json"
        params: {
            deviceId: "d-01JD5VY2K7M9Q4R6T8V0X2Z4B6"
            ssid: "Venue / Media"
            passphrase: "correct horse battery"
            hidden: false
        }
    }
    {
        id: "SetAnOpenWifiNetwork"
        documentation: "Without a passphrase, the network is open."
        protocol: restJson1
        method: "PUT"
        uri: "/v1/control/devices/d-01JD5VY2K7M9Q4R6T8V0X2Z4B6/wifi/networks"
        headers: { "Content-Type": "application/json" }
        body: """
            {
              "ssid": "Cafe"
            }
            """
        bodyMediaType: "application/json"
        params: {
            deviceId: "d-01JD5VY2K7M9Q4R6T8V0X2Z4B6"
            ssid: "Cafe"
        }
    }
])
@http(method: "PUT", uri: "/v1/control/devices/{deviceId}/wifi/networks", code: 200)
operation SetWifiNetwork {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        ssid: WifiSsid

        /// WPA2/WPA3-Personal. Left out for an open network.
        passphrase: WifiPassphrase

        /// The network doesn't broadcast its SSID, so the device probes for it.
        hidden: Boolean = false
    }

    output := {
        /// The network as the device saved it.
        @required
        network: WifiNetwork
    }

    errors: [
        DeviceNotFound
        DeviceUnreachable
        WifiNetworkRefused
    ]
}

/// Removes a Wi-Fi network from the device (an AWS IoT command execution, helios-net-wifi-remove,
/// Helios's net.wifi.remove). Removing one the device doesn't have succeeds. The device must be
/// online, as for SetWifiNetwork.
@idempotent
@httpRequestTests([
    {
        id: "DeleteAWifiNetworkBySsid"
        documentation: "The SSID is a query parameter, so any characters work."
        protocol: restJson1
        method: "DELETE"
        uri: "/v1/control/devices/d-01JD5VY2K7M9Q4R6T8V0X2Z4B6/wifi/networks"
        queryParams: ["ssid=Venue%20%2F%20Media"]
        params: {
            deviceId: "d-01JD5VY2K7M9Q4R6T8V0X2Z4B6"
            ssid: "Venue / Media"
        }
    }
])
@http(method: "DELETE", uri: "/v1/control/devices/{deviceId}/wifi/networks", code: 200)
operation DeleteWifiNetwork {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        @httpQuery("ssid")
        ssid: WifiSsid
    }

    output := {
        /// Whether the device had the network.
        @required
        removed: Boolean
    }

    errors: [
        DeviceNotFound
        DeviceUnreachable
        WifiNetworkRefused
    ]
}

// --- Streams -------------------------------------------------------------------------------

/// Lists a device's streams, desired and reported.
@readonly
@http(method: "GET", uri: "/v1/control/devices/{deviceId}/streams", code: 200)
operation ListStreams {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId
    }

    output := {
        @required
        streams: StreamList
    }

    errors: [
        DeviceNotFound
        DeviceStateUnavailable
    ]
}

/// Gets one stream, desired and reported.
@readonly
@http(method: "GET", uri: "/v1/control/devices/{deviceId}/streams/{streamId}", code: 200)
operation GetStream {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        @httpLabel
        streamId: StreamId
    }

    output := {
        @required
        stream: StreamDescription
    }

    errors: [
        DeviceNotFound
        StreamNotFound
    ]
}

/// Sets a stream live: it runs whenever its source is there. Idempotent.
@idempotent
@http(method: "POST", uri: "/v1/control/devices/{deviceId}/streams/{streamId}/start", code: 202)
operation StartStream {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        @httpLabel
        streamId: StreamId

        @idempotencyToken
        clientToken: ClientToken
    }

    output: StreamChangeOutput

    errors: [
        DeviceNotFound
        StreamNotFound
    ]
}

/// Sets a stream stopped. Idempotent.
@idempotent
@http(method: "POST", uri: "/v1/control/devices/{deviceId}/streams/{streamId}/stop", code: 202)
operation StopStream {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        @httpLabel
        streamId: StreamId

        @idempotencyToken
        clientToken: ClientToken
    }

    output: StreamChangeOutput

    errors: [
        DeviceNotFound
        StreamNotFound
    ]
}

/// Changes a stream's source, profile or bitrate. Members left out are unchanged. The
/// destination has its own operation, SetStreamDestination.
@idempotent
@httpRequestTests([
    {
        id: "UpdateStreamToARtmpSourceAndProfile"
        documentation: "A source union, a profile name and a bitrate override in the body."
        protocol: restJson1
        method: "PATCH"
        uri: "/v1/control/devices/d-01JD5VY2K7M9Q4R6T8V0X2Z4B6/streams/pocket"
        headers: { "Content-Type": "application/json" }
        body: """
            {
              "source": { "rtmp": { "key": "ingest" } },
              "profile": "hevc-720p",
              "bitrate": { "overrideKbps": 3000 },
              "clientToken": "6a1f0c2e-1111-4222-8333-944455556666"
            }
            """
        bodyMediaType: "application/json"
        params: {
            deviceId: "d-01JD5VY2K7M9Q4R6T8V0X2Z4B6"
            streamId: "pocket"
            source: { rtmp: { key: "ingest" } }
            profile: "hevc-720p"
            bitrate: { overrideKbps: 3000 }
            clientToken: "6a1f0c2e-1111-4222-8333-944455556666"
        }
    }
])
@http(method: "PATCH", uri: "/v1/control/devices/{deviceId}/streams/{streamId}", code: 202)
operation UpdateStream {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        @httpLabel
        streamId: StreamId

        source: Source

        profile: ProfileName

        bitrate: BitrateSetting

        sourceCeilingPercent: SourceCeilingPercent

        @idempotencyToken
        clientToken: ClientToken
    }

    output: StreamChangeOutput

    errors: [
        DeviceNotFound
        StreamNotFound
        SettingUnavailable
    ]
}

/// Sets where a stream's video goes: an SRT or SRTLA URL (DestinationUrl). Its own operation
/// because it decides where a device's video is sent; the response shows the previous
/// destination as well as the new one.
@idempotent
@httpRequestTests([
    {
        id: "SetStreamDestinationToAnSrtUrl"
        documentation: "The destination is one URL in the body."
        protocol: restJson1
        method: "PUT"
        uri: "/v1/control/devices/d-01JD5VY2K7M9Q4R6T8V0X2Z4B6/streams/pocket/destination"
        headers: { "Content-Type": "application/json" }
        body: """
            {
              "url": "srt://ingest.example.com:4001?streamid=publish/live/pocket&latency=2000",
              "clientToken": "6a1f0c2e-1111-4222-8333-944455556666"
            }
            """
        bodyMediaType: "application/json"
        params: {
            deviceId: "d-01JD5VY2K7M9Q4R6T8V0X2Z4B6"
            streamId: "pocket"
            url: "srt://ingest.example.com:4001?streamid=publish/live/pocket&latency=2000"
            clientToken: "6a1f0c2e-1111-4222-8333-944455556666"
        }
    }
])
@http(method: "PUT", uri: "/v1/control/devices/{deviceId}/streams/{streamId}/destination", code: 202)
operation SetStreamDestination {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        @httpLabel
        streamId: StreamId

        @required
        url: DestinationUrl

        @idempotencyToken
        clientToken: ClientToken
    }

    output := {
        @required
        stream: StreamDescription

        /// The destination before this change (the desired one if set, else the reported one).
        previous: DestinationUrl

        @required
        shadowVersion: Long
    }

    errors: [
        DeviceNotFound
        StreamNotFound
        InvalidDestination
    ]
}

/// Asks the device for the stream's status now (a stream.status command), with its recent log
/// lines. Fails with DeviceUnreachable if the device doesn't answer in time.
@readonly
@http(method: "GET", uri: "/v1/control/devices/{deviceId}/streams/{streamId}/status", code: 200)
operation GetStreamStatus {
    input := {
        @required
        @httpLabel
        deviceId: DeviceId

        @required
        @httpLabel
        streamId: StreamId
    }

    output := {
        @required
        stream: StreamReported

        /// The stream's most recent encoder log lines, oldest first.
        log: LogLines
    }

    errors: [
        DeviceNotFound
        StreamNotFound
        DeviceUnreachable
    ]
}

/// What a change returns: the stream with the new desired state, and the shadow version
/// written. The device applies it later; GetStream shows when reported has caught up.
structure StreamChangeOutput {
    @required
    stream: StreamDescription

    @required
    shadowVersion: Long
}

// --- Shapes: devices -----------------------------------------------------------------------

structure DeviceSummary {
    @required
    deviceId: DeviceId

    @required
    thingName: ThingName

    @required
    role: DeviceRole

    @required
    status: DeviceStatus

    /// Whether the device is connected to AWS IoT now, if known.
    connected: Boolean

    /// When it last connected or disconnected.
    connectionChangedAt: DateTime

    /// The Helios version it last reported.
    heliosVersion: String
}

list DeviceSummaryList {
    member: DeviceSummary
}

/// A module's state, from the `helios` shadow: for example running, failed, disabled.
@length(min: 1, max: 32)
string ModuleState

map ModuleStateMap {
    key: ModuleName
    value: ModuleState
}

@length(min: 1, max: 32)
@pattern("^[a-z][a-z0-9-]*$")
string ModuleName

// --- Shapes: inputs ------------------------------------------------------------------------

list InputList {
    member: Input
}

/// Something a device can stream from.
union Input {
    camera: CameraInput
    audio: AudioInput
    rtmp: RtmpIngestInput
    test: TestPatternInput
}

/// A USB camera (or HDMI capture device): a V4L2 capture node, and its own audio if it has one.
structure CameraInput {
    /// How to select it as a source: its key (`<vid>:<pid>:<serial>`) if it has a serial
    /// number, else its port (`usb:<port>`), which changes if it's plugged in elsewhere.
    @required
    selector: DeviceSelector

    /// Its USB port, for example 1-1.3.
    @required
    port: UsbPort

    product: String

    manufacturer: String

    /// Whether it has its own audio capture device.
    @required
    hasAudio: Boolean

    /// What it can capture, if the device has read it (V4L2).
    formats: VideoFormatList
}

/// An audio-only capture device (a USB microphone), which a camera source can pair with.
structure AudioInput {
    @required
    selector: DeviceSelector

    @required
    port: UsbPort

    product: String

    manufacturer: String
}

/// An RTMP ingest key: a camera publishes to it (push), and a stream reads it.
structure RtmpIngestInput {
    @required
    key: RtmpKey

    /// The URL to set on the camera, with the device's LAN address, for example
    /// rtmp://192.168.5.31:1935/live/ingest. Absent if the device has no LAN address now.
    publishUrl: String

    /// Who is publishing to the key now, if anyone.
    publisher: RtmpPublisher
}

structure RtmpPublisher {
    /// The camera's IP address.
    @required
    address: String

    @required
    since: DateTime

    /// The incoming video, from nginx's statistics: codec (for example H264), size and bitrate.
    videoCodec: String

    width: Integer

    height: Integer

    videoKbps: Integer
}

/// The generated test pattern (with a tone).
structure TestPatternInput {}

structure VideoFormat {
    /// The V4L2 pixel format or codec: for example MJPG, YUYV, H264.
    @required
    pixelFormat: String

    @required
    width: Integer

    @required
    height: Integer

    /// The frame rates offered at this size.
    @required
    fps: FpsList
}

list VideoFormatList {
    member: VideoFormat
}

list FpsList {
    member: Float
}

/// `usb:<port>` (for example usb:1-1.3) or `<vid>:<pid>:<serial>` (for example
/// 0bda:5830:CAM1), as in the device's configuration.
@length(min: 5, max: 200)
@pattern("^(usb:[0-9]+-[0-9]+(\\.[0-9]+)*|[0-9a-fA-F]{4}:[0-9a-fA-F]{4}:[^\\s]+)$")
string DeviceSelector

/// A USB port as the kernel names it: bus, then the port chain (for example 1-1.3).
@pattern("^[0-9]+-[0-9]+(\\.[0-9]+)*$")
string UsbPort

/// An RTMP ingest key: `ingest`, or `ingest-<n>` for additional cameras (owner's convention).
@pattern("^ingest(-[1-9][0-9]{0,2})?$")
string RtmpKey

// --- Shapes: profiles ----------------------------------------------------------------------

list ProfileList {
    member: ProfileDescription
}

/// An encoding profile defined on the device. Read-only here: profiles are defined in the
/// device's configuration.
structure ProfileDescription {
    @required
    name: ProfileName

    /// The video encoder: copy, libx264, libx265, h264_rkmpp, hevc_rkmpp, h264_v4l2m2m.
    @required
    video: String

    /// What encodes: ffmpeg, belacoder or ceracoder.
    @required
    encoder: String

    @required
    bitrateMode: BitrateMode

    @required
    bitrateKbps: Integer

    @required
    minBitrateKbps: Integer

    @required
    maxBitrateKbps: Integer

    /// WIDTHxHEIGHT, if the profile scales.
    scale: String

    /// aac, none or copy.
    @required
    audio: String
}

enum BitrateMode {
    FIXED = "fixed"
    ADAPTIVE = "adaptive"
}

/// A stream or profile name: letters, digits, - and _ (as on the device).
@length(min: 1, max: 64)
@pattern("^[A-Za-z0-9_-]+$")
string ProfileName

@length(min: 1, max: 64)
@pattern("^[A-Za-z0-9_-]+$")
string StreamId

// --- Shapes: streams -----------------------------------------------------------------------

list StreamList {
    member: StreamDescription
}

/// A stream: what's been asked of it (desired) and what the device reports (reported).
structure StreamDescription {
    @required
    streamId: StreamId

    @required
    desired: StreamDesired

    /// What the device last reported. Absent if it never has.
    reported: StreamReported

    /// Whether the device hasn't caught up with the desired state yet.
    @required
    pending: Boolean

    /// Desired values the device refused, and why.
    rejected: RejectedSettingList
}

structure StreamDesired {
    @required
    state: DesiredState

    /// Set only if changed through this API; else the stream's configured source applies.
    source: Source

    profile: ProfileName

    destination: DestinationUrl

    bitrate: BitrateSetting

    sourceCeilingPercent: SourceCeilingPercent
}

structure StreamReported {
    @required
    state: StreamState

    @required
    since: DateTime

    @required
    source: Source

    @required
    profile: ProfileName

    @required
    destination: DestinationUrl

    /// The bitrate in use, kbps: the override if there is one, else the profile's.
    @required
    bitrateKbps: Integer

    bitrateOverrideKbps: Integer

    /// An adaptive RTMP stream's ceiling from its camera's bitrate.
    bitrateCeilingKbps: Integer

    /// The camera's video bitrate (RTMP), kbps.
    sourceKbps: Integer

    encoder: EncoderFigures

    /// Active links of an SRTLA destination.
    activeLinks: Integer

    lastError: String
}

structure EncoderFigures {
    fps: Float

    bitrateKbps: Float

    dropFrames: Long

    dupFrames: Long

    speed: Float
}

enum DesiredState {
    LIVE = "live"
    STOPPED = "stopped"
}

/// Where a stream is in its life (LLD 4, section 6.4).
enum StreamState {
    STOPPED = "stopped"
    WAITING_FOR_INPUT = "waiting_for_input"
    STARTING = "starting"
    LIVE = "live"
    RECONNECTING = "reconnecting"
    FAILED = "failed"
}

/// Where a stream's video comes from: one of the inputs the device reports (ListInputs).
union Source {
    camera: CameraSource
    rtmp: RtmpSource
    test: TestSource
}

structure CameraSource {
    @required
    video: DeviceSelector

    /// Its audio: the camera's own (the same selector) or a separate audio device. Absent: none.
    audio: DeviceSelector
}

structure RtmpSource {
    @required
    key: RtmpKey
}

structure TestSource {
    /// WIDTHxHEIGHT, default 1280x720.
    @pattern("^[0-9]{2,4}x[0-9]{2,4}$")
    size: String

    @range(min: 1, max: 120)
    fps: Integer
}

/// A bitrate override, within the profile's limits, or back to the profile's own bitrate.
union BitrateSetting {
    overrideKbps: BitrateKbps

    /// Clears the override.
    profileDefault: Unit
}

@range(min: 100, max: 100000)
integer BitrateKbps

/// Adaptive RTMP streams: the ceiling follows the camera's bitrate times this percentage; 0
/// keeps the stream's bitrate as the ceiling.
@range(min: 0, max: 400)
integer SourceCeilingPercent

structure RejectedSetting {
    /// The desired member the device refused: source, profile, destination, bitrate,
    /// sourceCeilingPercent.
    @required
    setting: String

    @required
    reason: String

    @required
    at: DateTime
}

list RejectedSettingList {
    member: RejectedSetting
}

/// Log lines, for display only.
list LogLines {
    member: String
}

/// An SRT or SRTLA destination, and nothing else (owner, 2026-11-21):
///
///     srt://<host>:<port>?<parameters>      direct, over one uplink
///     srtla://<host>:<port>?<parameters>    bonded (srtla_rec), over the device's own uplinks
///
/// - host: a host name or IP address (letters, digits, - . _; an IPv6 address in brackets).
/// - port: 1 to 65535.
/// - parameters, each at most once, percent-encoded, and no others:
///   - streamid: up to 512 characters of letters, digits and / _ . - : = ,
///   - latency: milliseconds, 20 to 30000 (default 2000). Milliseconds, as in SRT's own URIs
///     (not ffmpeg's microseconds).
///   - passphrase: 10 to 79 characters of letters, digits and - . _ ~ ! $ ' ( ) * + , ; : @
///     (SRT passphrases aren't secrets here, owner 2026-11-21).
///
/// The pattern below checks only the shape; the service and the device check every rule above
/// and refuse anything else (InvalidDestination). The device builds its own SRT URL from the
/// parts, so this text never reaches a child process as-is.
@length(min: 10, max: 1024)
@pattern("^srt(la)?://(\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9._-]+):[0-9]{1,5}(\\?[^\\s#]*)?$")
string DestinationUrl

/// Makes a change safe to retry: the same token within an hour returns the first result.
@length(min: 1, max: 64)
@pattern("^[A-Za-z0-9_-]+$")
string ClientToken

// --- Shapes: Wi-Fi -------------------------------------------------------------------------

/// A Wi-Fi network's name. At most 32 bytes in UTF-8: the device refuses a longer one.
@length(min: 1, max: 32)
string WifiSsid

/// A WPA2/WPA3-Personal passphrase: 8 to 63 printable ASCII characters, or a 64-digit hex
/// pre-shared key (which can't be used for WPA3).
@sensitive
@length(min: 8, max: 64)
@pattern("^([ -~]{8,63}|[0-9A-Fa-f]{64})$")
string WifiPassphrase

/// A network the device is set to join. Never includes the passphrase.
structure WifiNetwork {
    @required
    ssid: WifiSsid

    /// open or personal.
    @required
    security: WifiSecurity

    @required
    hidden: Boolean
}

enum WifiSecurity {
    OPEN = "open"
    PERSONAL = "personal"
}

list WifiNetworkList {
    member: WifiNetwork
}

// --- Errors --------------------------------------------------------------------------------

/// The device has no stream with this ID.
@error("client")
@httpError(404)
structure StreamNotFound {
    message: String
}

/// The device hasn't reported this yet (it may never have connected).
@error("client")
@httpError(409)
structure DeviceStateUnavailable {
    message: String
}

/// The source or profile isn't one the device last reported: not attached, not an ingest key
/// it has, or not one of its profiles. The device would refuse it.
@error("client")
@httpError(409)
structure SettingUnavailable {
    message: String

    /// source or profile.
    setting: String
}

/// The destination isn't an SRT or SRTLA URL within DestinationUrl's rules.
@error("client")
@httpError(400)
structure InvalidDestination {
    message: String

    /// The part that's wrong: scheme, host, port, a parameter's name or value.
    part: String
}

/// The device refused the Wi-Fi change: it has no Wi-Fi adapter, already has the most networks
/// it keeps (16), found the SSID or passphrase invalid, couldn't open the sealed passphrase, or
/// can't take it at all (no key to seal to, or a Helios without Wi-Fi commands).
@error("client")
@httpError(409)
structure WifiNetworkRefused {
    message: String

    /// no_adapter, too_many, invalid_ssid, invalid_passphrase, secret_unreadable (the device
    /// couldn't open the sealed passphrase), no_secrets_key (the device reports no key to seal
    /// it to; nothing was sent), unsupported (its Helios has no Wi-Fi commands) or apply_failed.
    reason: String
}

/// The device didn't answer the command in time: it may be offline.
@error("server")
@httpError(504)
structure DeviceUnreachable {
    message: String
}
