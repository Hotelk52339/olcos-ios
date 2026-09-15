import SwiftUI

// MARK: - ConnectionRowView
//
// One row of the switcher list on the main screen. The connection the hero is
// about is not in this list, so a row's whole job is "which node is this, and
// does it work?": a localized service · transport line, the host label only
// when the list spans more than one host (`showHost`, decided once by the
// caller via `ConnectionNaming.spansMultipleHosts`), optional subscription
// metadata, and ONE `OlcHealthChip` — the same component the Manage VPS
// protocol rows draw, so "48 ms · now" means one thing in both places.
//
// A tap CONNECTS (`TunnelManager.connect(record:)` disconnects-then-dials, so
// it is safe from any state). Status is never colour alone: the chip carries a
// glow dot, a word and an age, and the word differs in every state. A failing row also carries its fix, inline; states
// that merely mean "not checked yet" keep the chip (tap = verify) and the pull
// gesture, because on a fresh install every row is one of them.

struct ConnectionRowView: View {

    let record: ConnectionRecord
    /// The honesty layer's dated verdict for this record.
    let display: HealthDisplay
    /// Screenshot-safe IP masking for the subscription meta line.
    let maskIPs: Bool
    let menuItems: [OlcMenuItem]
    /// Tap = connect through this node.
    let onConnect: () -> Void
    /// Tap on the chip, and the inline "Check" / "Retry" on a failing row.
    let onVerify: () -> Void
    /// Does the HOST line carry information on this screen? One VPS runs
    /// several protocols, so with one server the label is the same on every
    /// row. The caller decides once, in `ConnectionsView.recompute()`
    /// (`ConnectionNaming.spansMultipleHosts`), because this view is rebuilt
    /// ~10×/s during a speed test and may not derive it per row.
    var showHost = true

    var body: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Theme.Metrics.s2) {
                    // A real Button so VoiceOver gets the button trait and one
                    // activatable element; the chip and the overflow menu stay
                    // their OWN elements beside it. No `Spacer`: `infoColumn`
                    // already carries `maxWidth: .infinity`.
                    Button(action: onConnect) { infoColumn }
                        .buttonStyle(.plain)
                        // No `.layoutPriority` here: `infoColumn` is
                        // `maxWidth: .infinity`, and a priority on top would
                        // starve the chip. The chip cannot wrap by itself
                        // (one line each, scale then truncate), so the row
                        // stays two lines tall at most.
                        .accessibilityHint(L10n.connectRowTapHint.localized())
                    OlcHealthChip(display: display, onTap: onVerify)
                    OlcOverflowMenu(items: menuItems)
                }
                // OUTSIDE the connect Button: a button nested inside another
                // button does not reliably receive taps and reads as one control
                // to VoiceOver — and this is the control that repairs the node.
                problemBlock
            }
        }
    }

    // MARK: The subject — service, transport, and nothing else

    /// Identity first, machine last: the question a row answers is WHICH
    /// SERVICE the traffic hides inside, not whose machine it is — one VPS
    /// hosts several protocol containers, so the host is the same on every
    /// row. Two lines, so the transport (the half the owner asked to see) is
    /// never the part that gets cut; the break falls on " · ", never inside a
    /// word. The host label is a NAME, so it is not set in mono — mono is this
    /// app's mark for measured data.
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(ConnectionNaming.protocolLine(record.details))
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            hostLine
            metaLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// WHOSE machine — drawn only when the answer differs between rows.
    @ViewBuilder
    private var hostLine: some View {
        if showHost {
            Text(ConnectionNaming.host(record))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
    }

    /// Per-node subscription metadata (`##ip` / `##comment`), both
    /// server-supplied free text — rendered defensively, with no styling derived
    /// from the value.
    @ViewBuilder
    private var metaLine: some View {
        if record.subIP != nil || record.subComment != nil {
            HStack(spacing: Theme.Metrics.s2) {
                if let ip = record.subIP, !ip.isEmpty {
                    Text(IPMask.display(ip, masked: maskIPs))
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                if let comment = record.subComment, !comment.isEmpty {
                    Text(comment)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    // MARK: The problem, and the fix, offered where the problem is shown

    /// Only states that mean "something is wrong" get the reason spelled out and
    /// a full inline affordance. `.never` / `.stale` also suggest `.verify`, but
    /// on a fresh install EVERY row is `.never` — a block on all of them would be
    /// noise, so those keep the chip (tap = verify) and the pull gesture.
    private var fixAction: HealthAction? {
        switch display {
        case .broken, .inconclusive: return display.suggestedAction
        case .handshakeOnly:         return .verify
        default:                     return nil
        }
    }

    /// The reason and its fix, together, only on a row that has a problem.
    /// The chip beside the name already carries the verdict WORD; what the chip
    /// cannot fit is the sentence — for `.broken` that is `HealthReason.headline`
    /// — which is never truncated (HIG Typography).
    @ViewBuilder
    private var problemBlock: some View {
        if let action = fixAction {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(display.title)
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(display.tone.color)
                    .fixedSize(horizontal: false, vertical: true)
                inlineFix(action)
            }
            .padding(.top, Theme.Metrics.s2)
        }
    }

    @ViewBuilder
    private func inlineFix(_ action: HealthAction) -> some View {
        if let note = ConnectActionSite.elsewhereNote(for: action) {
            Label(note, systemImage: "arrow.forward.circle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            OlcButton(action.title, systemImage: "checkmark.shield",
                      role: .secondary, compact: true, action: onVerify)
        }
    }
}

// MARK: - ConnectionNaming
//
// ONE composition rule for "what does this connection call itself", read
// by the hero, by the switcher rows and by the Servers tab's protocol rows, so
// the same connection reads identically wherever it appears.
//
// Lives here as a top-level `enum` of pure statics (same shape as
// `ConnectActionSite` in ConnectHero.swift); nothing in it depends on SwiftUI.
//
// WHY IT EXISTS. ONE VPS runs SEVERAL protocol containers, so the identity
// question is "which service am I hiding inside?", not "whose machine".
// `ServersView.recordName` writes "ams-1 · telemost" (the RAW carrier id — a
// persisted token stays locale-stable) into `ConnectionRecord.name`; the
// service's name is drawn from it at render time.
//
// NOTHING HERE REWRITES STORED DATA. `ConnectionRecord.name`,
// `ConnectionDetails.subtitle` (the engineering form the connection log wants)
// and `ServersView.recordName` are untouched: the name links a record to its
// host and is what the user typed. This decides only what views SHOW, at render
// time.
//
// The separator is " · " (U+0020 U+00B7 U+0020) everywhere. Never a comma,
// never an em dash, never a slash.

enum ConnectionNaming {

    /// The SERVICE the traffic hides inside — the identity.
    /// "Yandex Telemost" / "Jitsi" / "WB Stream".
    static func service(_ details: ConnectionDetails) -> String {
        switch details {
        case .olcrtc(let p): return service(from: p.carrier)
        }
    }

    /// The same rule from a raw carrier id, for callers that hold one without a
    /// `ConnectionDetails` (the Servers tab's protocol rows).
    static func service(from carrier: String) -> String {
        CarrierTransportMatrix.carrierLabel(carrier)
    }

    /// HOW it is carried — "VP8" / "DataChannel".
    static func transport(_ details: ConnectionDetails) -> String {
        switch details {
        case .olcrtc(let p): return CarrierTransportMatrix.transportLabel(p.transport)
        }
    }

    /// Both, for one-line venues — "Jitsi · DataChannel".
    static func protocolLine(_ details: ConnectionDetails) -> String {
        "\(service(details)) · \(transport(details))"
    }

    /// WHOSE machine — the user's own label for the VPS, with the carrier suffix
    /// `ServersView.recordName` appends removed: the carrier is the headline
    /// above it and no line should say it twice.
    /// "ams-1 · Telemost" → "ams-1".
    ///
    /// Reads `displayName`, not `name`: `displayName` already substitutes
    /// `details.fallbackName` for a blank name, so this can never return "".
    static func host(_ record: ConnectionRecord) -> String {
        switch record.details {
        case .olcrtc(let p):
            return stripCarrierSuffix(name: record.displayName, carrier: p.carrier)
        }
    }

    /// Does a list of connections span MORE THAN ONE host label?
    ///
    /// With one server the host is the same word on every row.
    /// `ConnectionsView.recompute()` asks this once and passes the answer down
    /// as `ConnectionRowView.showHost`; nothing derives it inside a `body`.
    ///
    /// Short-circuits on the first disagreement, so the common answer (one host)
    /// still walks the list but the interesting one stops early. An empty list
    /// and a one-record list both span one host, i.e. `false`.
    static func spansMultipleHosts(_ records: [ConnectionRecord]) -> Bool {
        var first: String?
        for record in records {
            let label = host(record)
            if let first {
                if first != label { return true }
            } else {
                first = label
            }
        }
        return false
    }

    /// The pure, testable core of `host`. Conservative by construction: it
    /// strips ONLY when the trailing segment really is this record's carrier,
    /// and returns the name untouched in every other case — a user who named
    /// their server "prod · Frankfurt" keeps both halves.
    ///
    /// 1. trim the name;
    /// 2. find the LAST " · "; no separator ⇒ return the trimmed name;
    /// 3. an empty prefix ⇒ return the trimmed name (never return "");
    /// 4. compare the tail, normalised (lowercased, letters and digits only, so
    ///    "WB Stream" ≡ "wbstream"), against the raw carrier id AND its current
    ///    localized label; strip on a match, otherwise leave the name alone.
    static func stripCarrierSuffix(name: String, carrier: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = trimmed.range(of: " · ", options: .backwards) else { return trimmed }
        let prefix = String(trimmed[trimmed.startIndex..<sep.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return trimmed }
        let tail = normalizeForMatch(String(trimmed[sep.upperBound...]))
        guard !tail.isEmpty else { return trimmed }
        let candidates = [normalizeForMatch(carrier),
                          normalizeForMatch(CarrierTransportMatrix.carrierLabel(carrier))]
        if candidates.contains(tail) { return prefix }
        // Migration allowance: names are stamped with the label that was current
        // WHEN THE RECORD WAS CREATED, and labels have changed since ("Telemost"
        // → "Yandex Telemost"). A stored «ams-1 · Телемост» must still strip. The
        // 5-character floor keeps a short user word from matching by accident.
        if tail.count >= 5, candidates.contains(where: { $0.hasSuffix(tail) }) { return prefix }
        return trimmed
    }

    /// Case- and punctuation-insensitive comparison key. Deliberately keeps
    /// non-Latin letters ("Телемост" → "телемост") — the labels are localized.
    private static func normalizeForMatch(_ text: String) -> String {
        let kept: String = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return kept
    }
}
