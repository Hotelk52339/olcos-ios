// #456 was: import SwiftUI — the matrix TABLE view lived here; with it deleted
// (requirement 6) nothing in this file draws, so the SwiftUI dependency goes too.
import Foundation

// MARK: - CarrierTransportMatrix
//
// #456: this table is the **expected** layer ONLY. It is a hand-synced snapshot
// of upstream's E2E lab expectations at a pin — it cannot know what a third-party
// conferencing service is doing today, which is exactly how a field-dead
// telemost/vp8channel kept rendering as a green star. The **observed** layer is
// `HealthCoordinator` (measured, timestamped, persisted end-to-end probes), and
// that is what the UI now shows.
//
// What survives here, and why:
//   • `compat(carrier:transport:)` — functional gating of impossible chips in the
//     install / add-connection pickers (a ✗ cell disables the option);
//   • `defaultTransport(for:)` — the pre-selected transport per carrier;
//   • `requiresRoomID(carrier:)` / `autoGeneratesRoomID` — form requirements;
//   • `carrierLabel` / `transportLabel` — display names for raw IDs;
//   • `TunnelManager.failoverRank` — the TIEBREAK under `observedRank` (#456).
// The user-facing matrix TABLE (and its legend) is gone: it made claims about
// "what works" that nothing had measured.
//
// #284: re-derived from the upstream authoritative matrix in
// `olcrtc-upstream/docs/settings.md` (the "compatibility matrix", from the E2E
// suite). Legend mapping: `+` (pass) → .ok, the per-carrier best/default → .recommended,
// `~` (unstable, may work) → .question, `-` (fail / unsupported) → .fail.
//
// #357: re-synced to the upstream E2E ground truth (the realE2ECaseExpectation
// table in `olcrtc-upstream/internal/e2e/tunnel_test.go`), which is now more current
// than docs/settings.md for jitsi. E2E mapping: ExpectPass → .ok, ExpectUnstable →
// .question, ExpectFail → .fail.
//
// #434/#442: re-synced again to upstream master (f616f57). Jitsi's RTP-keepalive work
// landed for the remaining transports too — the E2E `case "jitsi"` now returns
// ExpectPass for ALL transports ("videochannel and seichannel now stable after RTP
// keepalive fixes"), so jitsi seichannel and videochannel flip .fail → .ok.
// telemost and wbstream rows are unchanged from master's table.
//
//   | transport    | telemost | wbstream | jitsi |
//   | datachannel  |    -     |    ~     |   +   |
//   | vp8channel   |    +     |    +     |   +   |
//   | seichannel   |    -     |    +     |   +   |
//   | videochannel |    +     |    +     |   +   |
//
// Upstream notes: Telemost dropped DataChannel (fail) and never supported sei;
// videochannel works but is slow. WBStream runs everything except datachannel
// (guest tokens set canPublishData=false → unstable). Jitsi's datachannel is the
// one stable, recommended combo; every other jitsi transport now passes E2E (#434).

/// Compatibility level between a carrier and a transport, based on upstream's
/// E2E expectations at the pinned submodule — NOT a claim about today.
///
/// #456 was: `symbol` (★/✓/?/✗/—), `spokenStatus` (VoiceOver words for those
/// glyphs) and `color` (Theme.Palette tints). All three existed only to draw the
/// deleted matrix table + legend; the remaining consumers switch on the case.
enum Compat {
    case recommended   // confirmed working upstream and preferred
    case ok            // confirmed working upstream
    case question      // uncertain / intermittent
    case fail          // confirmed broken / unsupported
    case unknown       // no data
}

enum CarrierTransportMatrix {
    static let carriers:   [String] = ["telemost", "wbstream", "jitsi"]
    static let transports: [String] = ["datachannel", "vp8channel", "seichannel", "videochannel"]

    /// Friendly, localised display names for the raw carrier / transport IDs
    /// (#283) — the pickers and matrix used to show bare IDs (`telemost`,
    /// `vp8channel`). The selection *value* stays the raw ID; only the label
    /// changes. Unknown IDs pass through so a future backend still renders.
    static func carrierLabel(_ id: String) -> String {
        switch id {
        case "telemost": return L10n.carrierTelemost.localized()
        case "wbstream": return L10n.carrierWbstream.localized()
        case "jitsi":    return L10n.carrierJitsi.localized()
        default:         return id
        }
    }
    static func transportLabel(_ id: String) -> String {
        switch id {
        case "datachannel":  return L10n.transportDatachannel.localized()
        case "vp8channel":   return L10n.transportVp8channel.localized()
        case "seichannel":   return L10n.transportSeichannel.localized()
        case "videochannel": return L10n.transportVideochannel.localized()
        default:             return id
        }
    }

    static let matrix: [String: [String: Compat]] = [
        "telemost": [
            "datachannel":  .fail,         // DataChannel removed from Telemost (upstream)
            "vp8channel":   .recommended,  // only stable transport for telemost; the default
            "seichannel":   .fail,         // not supported
            "videochannel": .ok,           // works but slow
        ],
        "wbstream": [
            "datachannel":  .question,     // guest tokens canPublishData=false → unstable
            "vp8channel":   .recommended,  // stable for commercial flows; the default
            "seichannel":   .ok,
            "videochannel": .ok,
        ],
        "jitsi": [
            "datachannel":  .recommended,  // the one stable combo upstream recommends everywhere
            "vp8channel":   .ok,           // #357: E2E ExpectPass since 95dc660 (jitsi RTP keepalive fix)
            // #434: master's E2E `case "jitsi"` returns ExpectPass for every transport.
            "seichannel":   .ok,           // #434 was: .fail — now E2E ExpectPass (RTP keepalive fixes landed for sei)
            "videochannel": .ok,           // #434 was: .fail — now E2E ExpectPass (RTP keepalive fixes landed for video)
        ],
    ]

    static func compat(carrier: String, transport: String) -> Compat {
        matrix[carrier]?[transport] ?? .unknown
    }

    /// Best transport to pre-select when user picks a carrier.
    static func defaultTransport(for carrier: String) -> String {
        switch carrier {
        case "jitsi":  return "datachannel"
        default:       return "vp8channel"
        }
    }

    /// Carriers that auto-generate a room ID when the user leaves the field
    /// empty. For every other carrier the room ID is mandatory and the
    /// install will fail server-side with "OLCRTC_ROOM_ID is required".
    ///
    /// Currently empty: every carrier requires an explicit room ID in the iOS UI.
    /// `scripts/srv.sh` *can* auto-generate a Jitsi room URL when OLCRTC_ROOM_ID
    /// is empty (#226), but the app keeps the field required for jitsi too,
    /// because the lightweight reconfigure path (`SSHRunner.reconfigureScript`)
    /// writes `room.id` verbatim and has no auto-gen — an empty room there would
    /// produce a broken config. Making the field optional for jitsi is deferred
    /// until reconfigure can auto-generate as well; if you add `"jitsi"` here,
    /// fix reconfigure in the same change.
    static let autoGeneratesRoomID: Set<String> = []

    /// Inverse of `autoGeneratesRoomID`. Unknown carriers default to
    /// `true` (Set.contains returns false), matching the server's
    /// "fail closed" behaviour.
    static func requiresRoomID(carrier: String) -> Bool {
        !autoGeneratesRoomID.contains(carrier)
    }
}

// #470: the chips every sheet shows are built HERE, from the matrix, so a test
// can hold them against the matrix instead of against a restatement of it.
extension CarrierTransportMatrix {
    static func transportOptions(for carrier: String) -> [OlcOption<String>] {
        transports.map { t -> OlcOption<String> in
            let fails = compat(carrier: carrier, transport: t) == .fail
            return OlcOption(value: t,
                             label: transportLabel(t),
                             disabled: fails,
                             disabledReason: fails ? L10n.matrixFail_fmt.formatted(carrierLabel(carrier)) : nil)
        }
    }
}
