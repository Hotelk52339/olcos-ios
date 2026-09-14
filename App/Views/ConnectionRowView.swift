import SwiftUI

// MARK: - ConnectionRowView (#457, cut down #459)
//
// #457: the SEMANTIC INVERSION fix, and the retirement of "primary".
//
// The old row (`ConnectionsView.serverRow`) carried status in COLOUR alone: a
// 24 pt aurora circle with a white bolt for the live node, an amber ring plus a
// "Main" capsule for the selected one, an empty grey ring otherwise, and a 7 pt
// coloured dot inside `OlcHealthChip`. Five states, one shape, no glyph and —
// in the chip — no word at all. Under Accessibility → Colour Filters →
// Grayscale the whole vocabulary collapsed. WCAG 2.2 SC 1.4.1 and Apple's
// "Differentiate Without Color Alone" both fail on that.
//
// #457 was: tapping a row called `store.setPrimary` + `Haptics.tap()` and did
// NOT connect — the most natural gesture in the app produced a gold star and a
// buzz and no connection, while "Connect" appeared in the overflow menu only on
// rows that were NOT already primary, i.e. missing on the row you most wanted.
// A tap now CONNECTS (`TunnelManager.connect(record:)` disconnects-then-dials,
// so it is safe from any state); the caller keeps `store.primary` in step as a
// side effect, purely so auto-connect-on-launch still has a record to read.
//
// #459: THE ROW IS TWO LINES. This list is a SWITCHER — the connection the hero
// is about is not in it at all — so a row's whole job is "which node is this,
// and does it work?". It says that in a name, a localized carrier·transport
// line, and ONE `OlcHealthChip`.
//
// #459 was: four lines under the name — `record.subtitle` ("olcrtc · jitsi ·
// datachannel", whose first word is on every row and carries no bits), a
// hand-rolled `verdictLine` (glyph + `display.title`), an `evidenceLine`
// (`display.subtitle`) and, on the live row, a "Live" badge plus an aurora
// spine. The glyph/word/age trio was the SAME three channels `OlcHealthChip`
// already renders — the chip the Manage VPS protocol rows use — so the row was
// re-implementing a shared component beside itself. That duplication IS the
// "lots of unnecessary and repeated details and words" in the brief.
//
// All three channels survive inside the chip: glyph (`OlcHealthGlyph.symbol`),
// word (`chipLabel`, falling back to `display.title`), age. It is already
// grayscale-safe, already wraps to two lines rather than truncating, and its
// 44 pt tap target RE-VERIFIES — which is why the row menu no longer carries a
// "Verify" item either.
//
// `isLive` / `liveBadge` / `auroraSpine` are gone because the live node is
// never in this list: a "Live" badge that can never render is dead code.
//
// #471: AND THE HOST LINE IS CONDITIONAL. One VPS runs several protocol
// containers here — the premise of the whole #461 inversion — so on a
// single-server install the host label was the same word printed under every
// name. `showHost` is decided once by the caller
// (`ConnectionNaming.spansMultipleHosts`); the row's title moves to
// `Theme.Typography.bodyStrong`, the identical value through the token, which is
// the pair `ProtocolRowView` on the Servers tab now draws too — one protocol,
// one look, on both tabs.
//
// A failing row still carries its FIX, and grows to do it. `HealthDisplay
// .suggestedAction` was already computed and simply never rendered, so the key
// mismatch headline was a dead end unless the user thought to open an overflow
// menu. Re-checking runs here; everything else names the screen it lives on
// rather than drawing a button that cannot work (see `ConnectActionSite`).
// Complexity appears only where there is a problem.

struct ConnectionRowView: View {

    let record: ConnectionRecord
    /// The honesty layer's dated verdict for this record.
    let display: HealthDisplay
    /// #337: screenshot-safe IP masking for the subscription meta line.
    let maskIPs: Bool
    let menuItems: [OlcMenuItem]
    /// Tap = connect through this node.
    let onConnect: () -> Void
    /// Tap on the chip, and the inline "Check" / "Retry" on a failing row.
    let onVerify: () -> Void
    /// #471: does the HOST line carry information on this screen? A line that
    /// prints the same word on every row carries none — and the whole rationale
    /// for the #461 identity inversion (see `ConnectionNaming`) is that one VPS
    /// runs several protocols, so the server label IS the same everywhere. The
    /// caller decides once, in `ConnectionsView.recompute()`
    /// (`ConnectionNaming.spansMultipleHosts`), because this view is rebuilt
    /// ~10×/s during a speed test and may not derive it per row.
    /// `var` (not `let`) so the memberwise init keeps the default.
    var showHost = true

    var body: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Theme.Metrics.s2) {
                    // #457: a real Button (not an `onTapGesture`) so VoiceOver
                    // gets the button trait and one activatable element, while
                    // the chip and the overflow menu stay their OWN elements
                    // beside it — the old row used `.accessibilityElement(
                    // children: .combine)` on the whole card, which swallowed
                    // both.
                    // #459: no `Spacer` beside it — `infoColumn` already carries
                    // `maxWidth: .infinity`, and two greedy siblings would split
                    // the slack and squeeze the chip into a needless wrap.
                    Button(action: onConnect) { infoColumn }
                        .buttonStyle(.plain)
                        .accessibilityHint(L10n.connectRowTapHint.localized())
                    // #459: the row's WHOLE status vocabulary, and its verify
                    // affordance — the same component the Manage VPS protocol
                    // rows draw, so "48 ms · 2m" means one thing in both places.
                    OlcHealthChip(display: display, onTap: onVerify)
                    OlcOverflowMenu(items: menuItems)
                }
                // #457: OUTSIDE the connect Button. A button nested inside another
                // button does not reliably receive taps and reads as one control
                // to VoiceOver — and this is the control that repairs the node.
                problemBlock
            }
        }
    }

    // MARK: The subject — name, kind, and nothing else

    // boc #461
    /// #461: THE IDENTITY INVERSION. The two lines swapped roles.
    ///
    /// #461 was: line 1 = `record.displayName` ("zaza · Telemost" — the label
    /// the user typed for their VPS, with the carrier suffix `ServersView
    /// .recordName` appends), line 2 = the carrier·transport in a MONOSPACED
    /// caption. The owner's verdict on the same inversion in the hero: "why the
    /// hell should I look at the fact that zaza is connected?"
    ///
    /// One VPS here hosts SEVERAL protocol containers, so the question a row
    /// answers is WHICH SERVICE the traffic hides inside — not whose machine it
    /// is, which is the same machine on every row. Mullvad renders
    /// "Netherlands, Amsterdam" over "nl-ams-wg-001"; IVPN renders "Amsterdam
    /// (nl-ams-01), NL"; Windscribe renders a bold city over a regular
    /// datacenter nickname. Identity first, machine last, in all of them.
    ///
    /// The host label drops the monospaced face with the demotion: a server
    /// label is a NAME, not a measurement, and mono is this app's mark for
    /// measured data (ages, milliseconds, ports).
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {   // #471 was: 2
            Text(ConnectionNaming.protocolLine(record.details))
                // #471: the identical value, through the token — a locally
                // re-declared font is how a six-step scale drifts back into
                // "two sizes plus a lot of weight". `ProtocolRowView` (Servers)
                // is aligned to the same two tokens, so one protocol reads the
                // same on both tabs.
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Palette.textPrimary)
                // #461 (audit) was: `.lineLimit(1)`, carried over from the line
                // that used to live here. That line was `record.displayName`
                // ("zaza · Telemost", ~15 characters); this one is
                // "Yandex Telemost · DataChannel" — 29 characters at the body
                // step, in a labels column left with ~150 pt once the evidence
                // chip and the fixed 44 pt menu have taken theirs. At one line
                // the TRANSPORT is what gets cut, i.e. exactly the half the
                // owner asked to be shown. Two lines, for the same reason and
                // with the same guarantee as `ProtocolRowView.labels`: the
                // break falls on the space around " · ", never inside a word.
                .lineLimit(2)
            hostLine   // #471: only when the list spans more than one host
            metaLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    // eoc #461

    /// #471: WHOSE machine — drawn only when the answer differs between rows.
    /// With one server (the common install, and the shape this product is built
    /// around) every row printed the same label under its own name, which is a
    /// line of chrome pretending to be a fact.
    @ViewBuilder
    private var hostLine: some View {
        if showHost {
            Text(ConnectionNaming.host(record))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
    }

    // boc #461
    // #461 was: `detailLine` — this row's private carrier·transport helper, with
    // a TODO to "move it onto the model the next time that file is touched".
    // `ConnectionNaming` below IS that move: the hero, this row and the Servers
    // card read one rule, so the three can no longer drift.
    // eoc #461

    /// #363: per-node subscription metadata (`##ip` / `##comment`), both
    /// server-supplied free text — rendered defensively, with no styling derived
    /// from the value.
    @ViewBuilder
    private var metaLine: some View {
        if record.subIP != nil || record.subComment != nil {
            HStack(spacing: Theme.Metrics.s2) {   // #471 was: 6
                if let ip = record.subIP, !ip.isEmpty {
                    Text(IPMask.display(ip, masked: maskIPs))
                        .font(Theme.Typography.mono)   // #471: an address — mono stays
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                if let comment = record.subComment, !comment.isEmpty {
                    Text(comment)
                        .font(Theme.Typography.caption)   // #471 was: .caption2
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

    /// #459: the reason and its fix, together, only on a row that has a problem.
    /// The chip beside the name already carries the verdict WORD; what the chip
    /// cannot fit is the sentence — for `.broken` that is `HealthReason.headline`
    /// — which is never truncated (HIG Typography).
    @ViewBuilder
    private var problemBlock: some View {
        if let action = fixAction {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {   // #471 was: 4
                Text(display.title)
                    .font(Theme.Typography.captionStrong)   // #471: same value, via the token
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
                .font(Theme.Typography.caption)   // #471 was: .caption2
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            OlcButton(action.title, systemImage: "checkmark.shield",
                      role: .secondary, compact: true, action: onVerify)
        }
    }
}

// boc #459
// #459 was: `enum ConnectHealthGlyph` — a byte-identical copy of
// `OlcHealthGlyph` (App/UI/HealthChip.swift), which existed only to feed this
// row's hand-rolled verdict line. The row draws `OlcHealthChip` now, and the
// chip owns the mapping, so the duplicate is deleted rather than kept in sync.
// eoc #459

// MARK: - ConnectionNaming (#461)
//
// #461: ONE composition rule for "what does this connection call itself", read
// by the hero, by the switcher rows and by the Servers tab's protocol rows, so
// the same connection reads identically wherever it appears.
//
// PARTITION NOTE: the design calls for this in its own file,
// `App/Models/ConnectionNaming.swift`. This change may not create files, so it
// lives here as a top-level `enum` of pure statics — the same shape and the
// same precedent as `ConnectActionSite` at the bottom of ConnectHero.swift.
// Move it to App/Models on the next `xcodegen generate` pass; nothing in it
// depends on SwiftUI or on this row.
//
// WHY IT EXISTS. Our product is Amnezia's shape — ONE VPS running SEVERAL
// protocol containers — with Mullvad's identity question: which service am I
// hiding inside? We inherited Amnezia's "server name first" while our identity
// is the carrier. `ServersView.recordName` writes "zaza · telemost" into
// (#470: the RAW carrier id — a persisted token stays locale-stable, and the
// service's name is drawn from it at render time)
// `ConnectionRecord.name`, and every venue printed that verbatim.
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

    /// #461: the SERVICE the traffic hides inside — the identity.
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

    /// #461: HOW it is carried — "VP8" / "DataChannel".
    static func transport(_ details: ConnectionDetails) -> String {
        switch details {
        case .olcrtc(let p): return CarrierTransportMatrix.transportLabel(p.transport)
        }
    }

    /// #461: both, for one-line venues — "Jitsi · DataChannel".
    static func protocolLine(_ details: ConnectionDetails) -> String {
        "\(service(details)) · \(transport(details))"
    }

    /// #461: WHOSE machine — the user's own label for the VPS, with the carrier
    /// suffix `ServersView.recordName` appended removed, because the carrier is
    /// now the headline above it and no line should say it twice.
    /// "zaza · Telemost" → "zaza".
    ///
    /// Reads `displayName`, not `name`: `displayName` already substitutes
    /// `details.fallbackName` for a blank name, so this can never return "".
    static func host(_ record: ConnectionRecord) -> String {
        switch record.details {
        case .olcrtc(let p):
            return stripCarrierSuffix(name: record.displayName, carrier: p.carrier)
        }
    }

    // boc #471
    /// #471: does a list of connections span MORE THAN ONE host label?
    ///
    /// The switcher rows print `host` under each name, and with one server —
    /// this product's own shape, one VPS running several protocol containers —
    /// that is the same word on every row. `ConnectionsView.recompute()` asks
    /// this once and passes the answer down as `ConnectionRowView.showHost`;
    /// nothing derives it inside a `body`.
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
    // eoc #471

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
        // #461: the migration allowance. Names are stamped with the label that
        // was current WHEN THE RECORD WAS CREATED, and `carrierTelemost` changes
        // value in this same change ("Telemost" → "Yandex Telemost", «Телемост»
        // → «Яндекс Телемост»). A stored «zaza · Телемост» must still strip. The
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
