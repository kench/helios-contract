$version: "2"

namespace tv.kenley.helios.device

use tv.kenley.helios.control#BitrateKbps
use tv.kenley.helios.control#ProfileName
use tv.kenley.helios.control#Source
use tv.kenley.helios.control#SourceCeilingPercent
use tv.kenley.helios.control#StreamId

/// The commands the cloud sends to a device, and the device's answers (LLD 2, section 7.3; the
/// page "Helios - State Management: Tenets and Practices"). Not an HTTP API: each operation is
/// one AWS IoT command, `helios-<module>-<name>-v<n>`, whose payload Helios receives as
/// `{"module", "name", "timeout_s", "args"}` with `args` the base64 of the input below as JSON.
/// The device answers within the execution's timeout:
///
/// - SUCCEEDED, with the output below as the result's JSON, when it processed the command. A
///   command that changes settings is applied whole or not at all; refusals are in the output.
/// - FAILED, with a CommandFailureCode as `reasonCode`, when it couldn't process it at all.
///
/// Commands are never queued: a device that isn't connected doesn't answer, and the execution
/// times out. They are idempotent, so a caller retries a timed-out one as it is.
///
/// Field names are snake_case, as Helios's shadows and commands use. Settings use `set` for a
/// value and `configured` to go back to the device's `helios.toml`, never a null.
service HeliosDeviceCommands {
    version: "2026-11-26"
    operations: [
        StreamStart
        StreamStop
        StreamUpdate
        DisplayIdle
    ]
}

// --- stream --------------------------------------------------------------------------------

/// `helios-stream-start-v1` (Helios's `stream.start`): sets the stream live. The device starts
/// it as soon as its source is there; the answer comes once that's decided, not once the stream
/// is on air (its `state` then is `starting` or `waiting_for_input`).
operation StreamStart {
    input := {
        @required
        stream_id: StreamId
    }

    output: StreamStatusOutput
}

/// `helios-stream-stop-v1` (Helios's `stream.stop`): sets the stream stopped.
operation StreamStop {
    input := {
        @required
        stream_id: StreamId
    }

    output: StreamStatusOutput
}

/// `helios-stream-update-v1` (Helios's `stream.update`): changes any of a stream's settings at
/// once. The device checks them all first; if it refuses any, it changes nothing and lists every
/// refusal. Settings left out are unchanged. A change of source, profile, destination or
/// recording restarts a running stream's encoder once, whatever else changes with it; a bitrate
/// or ceiling alone doesn't.
operation StreamUpdate {
    input := {
        @required
        stream_id: StreamId

        source: SourceSetting

        profile: ProfileSetting

        destination: DestinationSetting

        bitrate: BitrateSetting

        source_ceiling_percent: SourceCeilingSetting

        record: RecordSetting
    }

    output := {
        /// The stream as it is after the command: changed if nothing was refused, else as before.
        @required
        status: StreamStatus

        /// Every setting the device refused. Present only when it changed nothing.
        refused: RefusedSettingList
    }
}

structure StreamStatusOutput {
    /// The stream as it is after the command.
    @required
    status: StreamStatus
}

/// The stream's entry in the `stream` shadow's reported state, as Helios reports it
/// (`streams.<id>`: state, since, desired, source, profile, bitrate_kbps, bitrate_override_kbps,
/// destination, overrides, rejected, recording, ...; LLD 4, section 6.4). Modelled in full in a
/// later version, with the reported shadows.
document StreamStatus

union SourceSetting {
    set: Source

    /// The stream's source in `helios.toml`.
    configured: Unit
}

union ProfileSetting {
    set: ProfileName

    /// The stream's profile in `helios.toml`.
    configured: Unit
}

union DestinationSetting {
    /// The SRT or SRTLA URL (the Control API's DestinationUrl rules), sealed to the device
    /// because AWS keeps a command's parameters: the URL can hold a passphrase.
    set: SealedValue

    /// The stream's destination in `helios.toml`.
    configured: Unit
}

union BitrateSetting {
    /// An override within the profile's limits. The profile's own bitrate counts as no override.
    set: BitrateKbps

    /// No override: the profile's bitrate.
    configured: Unit
}

union SourceCeilingSetting {
    set: SourceCeilingPercent

    /// The profile's `source_ceiling_percent`.
    configured: Unit
}

union RecordSetting {
    set: Boolean

    /// The stream's `record` in `helios.toml`.
    configured: Unit
}

// --- display -------------------------------------------------------------------------------

/// `helios-display-idle-v1` (Helios's `display.idle`): sets the idle screen, the one shown when
/// no `display.show` screen is up. A shown screen stays until it expires or is cleared. The idle
/// screen lasts until Helios restarts; then `helios.toml`'s `idle_template` applies again
/// (owner, 2026-11-26). Everything the device checks is in the model: a screen that doesn't
/// match it is `INVALID_MESSAGE`, and the device changes nothing.
operation DisplayIdle {
    input := {
        @required
        idle: IdleSetting
    }

    output := {
        /// The display as it is after the command.
        @required
        status: DisplayStatus
    }
}

/// The `display` shadow's reported state, as Helios reports it (template, shown_at, until, idle,
/// available, geometry, console_bound, time_zone, bold_font, error; LLD 9, section 7). Modelled
/// in full in a later version, with the reported shadows.
document DisplayStatus

union IdleSetting {
    set: Screen

    /// The `idle_template` in `helios.toml` (`status` by default).
    configured: Unit
}

/// A screen, by template (LLD 9, section 6). Text is trimmed and control characters other than
/// newlines are dropped before the lengths are checked; lengths are in characters.
union Screen {
    /// The connection, the device's address and the clock.
    status: Unit

    blank: Unit

    /// A test pattern for checking the panel.
    test: Unit

    message: MessageScreen

    result: ResultScreen
}

structure MessageScreen {
    @required
    title: ScreenTitle

    body: MessageBody

    /// `info` if left out.
    severity: MessageSeverity
}

structure ResultScreen {
    @required
    outcome: ResultOutcome

    title: ResultTitle

    body: ResultBody
}

@length(min: 1, max: 40)
string ScreenTitle

@length(max: 40)
string ResultTitle

@length(max: 300)
string MessageBody

@length(max: 160)
string ResultBody

enum MessageSeverity {
    INFO = "info"
    SUCCESS = "success"
    WARNING = "warning"
    ERROR = "error"
}

enum ResultOutcome {
    ACCEPTED = "accepted"
    REJECTED = "rejected"
}

/// A secret sealed to the device (LLD 3, section 10.7): HPKE base mode, DHKEM(P-256,
/// HKDF-SHA256), HKDF-SHA256, AES-128-GCM, to the key in the device's `helios` shadow
/// (`secrets_key`). `info` is `helios secret v1 <thing>`; the AAD names the purpose:
/// `stream.destination <stream_id>` for a destination, `wifi.passphrase <ssid>` for Wi-Fi.
structure SealedValue {
    @required
    sealed: Sealed
}

structure Sealed {
    /// The encapsulated key, base64url without padding.
    @required
    enc: String

    /// The ciphertext with its tag, base64url without padding.
    @required
    ct: String
}

list RefusedSettingList {
    member: RefusedSetting
}

structure RefusedSetting {
    /// The input member refused: source, profile, destination, bitrate,
    /// source_ceiling_percent or record.
    @required
    setting: String

    /// Why, for people: "no profile \"hevc-4k\"", "outside the profile's limits (500-2000)",
    /// "the sealed destination can't be opened", ...
    @required
    reason: String
}

/// A FAILED answer's `reasonCode`: the device couldn't process the command at all.
enum CommandFailureCode {
    /// The arguments don't match the input, or the stream doesn't exist.
    INVALID_MESSAGE = "INVALID_MESSAGE"

    /// The device's Helios doesn't have this command (it's older). The caller can fall back.
    UNKNOWN_COMMAND = "UNKNOWN_COMMAND"

    /// The module isn't running on the device.
    MODULE_UNAVAILABLE = "MODULE_UNAVAILABLE"

    /// The device couldn't finish within the deadline.
    TIMEOUT = "TIMEOUT"

    INTERNAL = "INTERNAL"
}
