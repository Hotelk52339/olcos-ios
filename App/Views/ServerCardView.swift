import SwiftUI

// MARK: - ServerCardView (#457)
//
// #457: one VPS card, cut out of `ServersView` (`hostCard` / `hostCardTop` /
// `hostCardBottom` / `statusRegion` / `processCaption` / `metricsStrip` /
// `actionBar` / `primaryButton` / `protocolsSection` / `healthSweepFooter`).
// ServersView has hit the Swift type-checker's expression budget twice, so the
// card is a small value-driven struct: every input is a plain value or a
// closure, explicitly typed, and every sub-view here stays under ~20 lines.
//
// Reading order on the card is the order of the questions the owner asks:
//   1 which server is this        → header (+ the machine, as ONE caption)
//   2 what is true right now      → the status pill, and nothing else
//   3 what runs on it, does it work → PROTOCOLS (the content)
//   4 what do I do next           → ONE full-width action
//   5 what else can I do to it    → "Logs" / "Manage ›", one row of links
//
// boc #471: five answers, not six — and each of them stated ONCE. The card used
// to say its one claim three times (pill → `readStamp` → `failureBanner`), its
// one age three times (pill subtitle, read stamp, each row's chip) and a
// millisecond value twice in two different units (the health chip's end-to-end
// latency, and PING — a TCP-22 round-trip — in the metrics grid beside it).
// What left the card in this pass, and where each fact went:
//   • `readStamp` → `HostHeadline.reduce` dates the claim it qualifies;
//   • `failureBanner` → the same headline's tally ("2 of 2 protocols
//     verified 2 min ago"), so "Working" and "not working" never share a card;
//   • `ServerMetricsGrid` → one tertiary caption under the address
//     (disk / RAM / uptime) plus read-only rows on the Manage screen;
//   • PING → the Manage screen only. The pill's `.unreachable` state already
//     says whether the host answers, and a TCP-22 round-trip is not a user
//     fact — it only ever contradicted the verified latency on the row below;
//   • `quickRow` → a text link beside "Manage ›", so the card ends on ONE
//     filled button instead of three action treatments.
// eoc #471
//
// boc #459: the card grows into the empty half of the Servers screen instead of
// something new being invented to fill it — 20pt between blocks, roomier
// protocol rows, and the affordances the owner reached for most often (Container
// logs, the primary verb, and the way to everything else) visible on the card
// rather than buried in a 13-item ⋯ menu.
// #461 was: "the four affordances", Check server among them — it duplicated
// pull-to-refresh, so it is gone (ServersView.quickActions).
// #471 was: "roomier protocol rows" meant each row drew its own plate; and the
// last of the promoted affordances (Container logs) was still a full-width
// button. Rows separate with a hairline now and the verb is a link.
// What LEFT the card in the same pass:
//   • the process caption ("Server process is running · read 2m ago") — it
//     restated the status pill and each protocol row already says whether its
//     own container is up. Only its AGE was load-bearing, so the age survives
//     as the read stamp — on the metrics block then, under the status pill
//     since #461, and nothing else of it does.
//   • the sweep note ("N more not checked — tap Verify all") — a footnote
//     advertising a button that pull-to-refresh replaces. Every skipped
//     protocol still says "not checked" in its own chip, which is the same
//     fact stated per item instead of in aggregate.
// eoc #459
//
// #457 was: four unlabelled 44pt icon buttons (antenna / arrow.down.doc /
// slider.horizontal.3 / RobotIcon) squeezing the primary action into a fifth of
// the row. Every one of them duplicated an item that is already in the overflow
// menu, so deleting them costs nothing and buys the primary action its width.

/// #457: the primary action a card is allowed to offer. The rule the old
/// `primaryButton` broke: never offer an action no evidence justifies. A server
/// nothing has ever read (`HostBase.unknown`) gets **Check server**, never
/// Install — `scripts/srv.sh` force-removes every `olcrtc-server-*` container,
/// so one tap on a re-added VPS used to destroy a working deployment.
enum ServerPrimaryAction: Equatable {
    case busy, retry, check, start, stop, install

    var isBusy: Bool { self == .busy }

    var title: String {
        switch self {
        case .busy:    return L10n.vpsWorking.localized()
        case .retry:   return L10n.actionRetry.localized()
        case .check:   return L10n.vpsCheckServer.localized()
        case .start:   return L10n.actionStart.localized()
        case .stop:    return L10n.actionStop.localized()
        case .install: return L10n.actionInstall.localized()
        }
    }

    var systemImage: String? {
        switch self {
        case .busy:    return nil
        case .retry:   return "arrow.clockwise"
        case .check:   return "antenna.radiowaves.left.and.right"
        case .start:   return "play.fill"
        case .stop:    return "stop.fill"
        case .install: return "arrow.down.app"
        }
    }

    var role: OlcButton.Role {
        switch self {
        case .busy: return .secondary
        // #471 was: `.danger`. On a healthy server the LOUDEST element of the
        // whole card was the action the owner wants least often, painted in the
        // colour this app reserves for destruction ("Wipe all olcrtc data").
        // Stopping is undone by the same button one tap later; red stays on the
        // Manage screen, where the irreversible verbs live.
        case .stop: return .secondary
        default:    return .primary
        }
    }
}

// #471 was: `struct ServerCardMetrics` — the input to `ServerMetricsGrid`,
// both deleted below. The type survives as `ServerMachineStats`
// (App/Views/ServerAdvancedView.swift), where the four readings are now
// read-only Form rows; the card keeps only the three that describe the MACHINE,
// pre-joined by ServersView into one caption (`machineLine`).

/// #471 was: the card's `quickRow` input. `ServerCardView` no longer draws a
/// quick-action button at all — "Container logs" is a text link in `manageRow`
/// — so nothing in the app builds one of these any more. The type stays because
/// `Review470Chunk6Tests.testQuickActionIdentityIsStableAcrossRebuilds` pins its
/// identity rule by name; delete both together.
///
/// #459: one visible quick action. It sat above the primary button — the verb
/// the owner reaches for constantly (Container logs), which used to cost a ⋯ tap
/// plus a scan of thirteen items. Value-driven and explicitly typed, like every
/// other input on this card, so the row costs the type-checker nothing.
/// #461 was: TWO of them, Check server first. `quickRow` still renders however
/// many it is handed, and only compacts them when there is more than one.
struct ServerQuickAction: Identifiable {
    // #470 was: `let id = UUID()` — a fresh identity on every parent render.
    // `ServersView.quickActions(host)` rebuilds this array on every body
    // evaluation (each provisioner line, each health tick, each tunnel
    // publish), so `ForEach(quickActions)` removed and re-inserted the button
    // every time — animated whenever the render was the one `.animation(value:
    // headline)` covers, and dropping a press held on it. The verb IS the
    // identity: same symbol + title ⇒ same button.
    var id: String { "\(systemImage)|\(title)" }
    let title: String
    let systemImage: String
    let action: () -> Void
}

struct ServerCardView: View {
    /// Server label.
    let name: String
    /// "user@host:port", already IP-masked by the caller.
    let addressLine: String
    /// The ONE headline (App/Models/HostDisplay.swift) — busy → op-failed →
    /// unreachable → never-checked → stopped → nothing-installed → measured health.
    let headline: HostHeadline
    /// Progress-bar fraction while an op runs; nil leaves the slot empty.
    let progress: Double?
    // boc #471: four inputs became one caption.
    // #471 was: `readCaption` (drawn by `readStamp`), `failingCount` /
    // `protocolCount` (drawn by `failureBanner`) and `metrics`
    // (`ServerMetricsGrid`). The age and the tally are arguments to
    // `HostHeadline.reduce` now, so they reach the card already folded into the
    // ONE claim the pill makes; the machine numbers reach it as one line.
    /// Disk / RAM / uptime, pre-joined by ServersView ("Disk 3.5/8.0G · RAM
    /// 0.4/1.9G · up 14 h"), or "" when nothing has been read — three em-dashes
    /// are noise, not honesty, and the pill already says the host has not
    /// answered. Built from the same `shortUsage` / `shortRAM` / `shortUptime`
    /// statics `VPSStatFormattingTests` pins by name.
    let machineLine: String
    // eoc #471
    let rows: [SSHRunner.CarrierInfo]
    /// A protocol-level op (add / remove / sibling start-stop) is in flight.
    let rowsBusy: Bool
    let listing: ServerProtocolListing // #490: never portray unread protocols as an empty successful scan.
    let canAddProtocol: Bool
    let actionsDisabled: Bool
    let primary: ServerPrimaryAction
    /// #471: there is a container on this server to read logs FROM. Before an
    /// install the card's whole offer is its primary CTA, so the Logs link is
    /// absent rather than opening an empty server — the same gate
    /// `ServersView.quickActions` used to apply to the button it replaces.
    /// #471 was: `quickActions: [ServerQuickAction]` — a full-width grey button
    /// stacked above the primary one, a THIRD action treatment on a card that
    /// has two.
    let canOpenLogs: Bool
    /// The safe, occasional action set for this server (5 items). Everything
    /// rare or destructive lives behind `onManage` (#459).
    let menuItems: [OlcMenuItem]
    let onPrimary: () -> Void
    let onAddProtocol: () -> Void
    /// #471: the container log — a text link beside "Manage ›" now, not a
    /// full-width button above the primary action.
    let onLogs: () -> Void
    /// #459: push the full server-management screen.
    let onManage: () -> Void
    /// Row factory — ServersView owns the resolution from a container to a record.
    let row: (SSHRunner.CarrierInfo) -> ProtocolRowView

    // #490: no animation is mounted for idle server listings.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool {
        if case .busy = headline { return true }
        return false
    }

    // boc #490
    // #490 was: one enclosing OlcCard and five equally spaced blocks. Signal
    // floats identity above an evidence/protocol plate and keeps the main action
    // outside it, so the server, its readings and its controls have clear ranks.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            header
            evidencePlate
            actions
            manageRow
        }
        .tint(Theme.Signal.stroke)
        .animation(reduceMotion ? nil : .easeOut(duration:
            ServerPresentationPolicy.transitionDuration(reduceMotion: reduceMotion)), value: headline)
    }

    private var evidencePlate: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                statusRegion
                if listing != .absent || !rows.isEmpty || canAddProtocol {
                    Divider().overlay(Theme.Palette.cardBorder)
                }
                protocolsSection
            }
        }
    }
    // eoc #490

    // MARK: 1 — identity

    private var header: some View {
        // #471: `8` / `1` → the grid. Same rhythm, through the tokens that name it.
        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(name)
                    // #471 was: `.font(.headline)` — the card's SUBJECT, drawn
                    // one step below the type scale's subject step.
                    .font(Theme.Typography.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader) // #490: identify each server to VoiceOver.
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(addressLine)
                    // #471 was: `.system(.caption, design: .monospaced)` — the
                    // same step, now through the token that names it (mono is
                    // for addresses and ports; this is one).
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                machineCaption
            }
            Spacer(minLength: Theme.Metrics.s2)
            OlcOverflowMenu(items: menuItems)
                .disabled(actionsDisabled)
        }
    }

    /// #471: the machine, demoted for real. `.monospacedDigit()` aligns the
    /// digits from card to card without putting a mono FACE on a sentence.
    /// No `lineLimit` and no `minimumScaleFactor`, for the reason the deleted
    /// grid had neither: a measured value that shrinks or truncates is a value
    /// the owner cannot read, and an unreadable truth was the whole failure.
    /// It dims with `isBusy` exactly as the grid did — a reading taken before
    /// the running op is the one thing on the card the op may already have
    /// invalidated.
    /// #471 was: `ServerMetricsGrid` — four uppercase tracked labels over
    /// body-size monospaced semibold values in a 2×2 grid: `df` / `free` /
    /// `uptime` at data-display weight inside a consumer card.
    @ViewBuilder
    private var machineCaption: some View {
        if !machineLine.isEmpty {
            Text(machineLine)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary) // #490 was: tertiary machine data.
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isBusy ? 0.45 : 1)
        }
    }

    // MARK: 2 — what is true right now
    //
    // boc #471: the pill, and nothing else.
    //
    // #471 was: `verdict` — a VStack of `statusRegion` + `readStamp` +
    // `failureBanner`, i.e. the card's one claim ("Working"), how old that
    // claim is ("read 2 min ago") and a contradiction of it ("1 of 2 protocols
    // are not working") stacked 8pt apart in three different weights and two
    // different tones. The age and the count are inputs to
    // `HostHeadline.reduce` now (App/Models/HostDisplay.swift), which folds
    // both into the pill's own subtitle — "2 of 2 protocols verified 2 min
    // ago" — and flips the title to "Partly working" when they disagree. One
    // claim, dated once, counted once.
    //
    // #461's placement argument survives the deletion intact: how old a claim
    // is belongs BESIDE the claim, never at the bottom edge of the card. The
    // subtitle is as beside it as a line can get.
    // eoc #471

    /// #341/#335: fixed footprint — the pill always occupies the same slot and
    /// the bar below only fades its opacity, so starting an op never reflows the
    /// card or animates the pill from one anchor to another.
    // boc #490
    // #490 was: OlcStatusPill with a hidden progress slot and a fixed 58pt floor.
    // Use the same complete dated headline, without a pulsing status decoration.
    private var statusRegion: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
            ServerSignalStatus(tone: headline.tone, title: headline.title,
                               subtitle: headline.subtitle, isBusy: isBusy)
            if let progress {
                ProgressView(value: progress)
                    .tint(Theme.Signal.stroke)
                    .accessibilityLabel(headline.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    // eoc #490

    // MARK: 3 — the protocols (the content)

    @ViewBuilder
    private var protocolsSection: some View {
        // #490 was: only known rows or an available Add action showed the section.
        if listing != .absent || !rows.isEmpty || canAddProtocol {
            // #471 was: `Theme.Metrics.s2 + 2` between rows that each drew their
            // own inset plate. The plate is gone (ProtocolRowView), so the rows
            // separate the way an inset list does — one grid step and a
            // hairline — and a protocol looks the same object here as it does
            // on Connect.
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                protocolsHeader
                listingNote // #490: truthful loading/unread state, without a new clock.
                ForEach(rows) { info in protocolRow(info) }
            }
            .opacity(isBusy ? 0.45 : 1)
        }
    }

    // boc #490
    @ViewBuilder private var listingNote: some View {
        if listing == .loading {
            Text(L10n.vpsWorking.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else if listing == .unread {
            Text(L10n.vpsProcessUnread.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    // eoc #490

    /// #471: the hairline goes ABOVE every row but the first, so the header
    /// keeps its own gap and the list never ends on a dangling separator.
    @ViewBuilder
    private func protocolRow(_ info: SSHRunner.CarrierInfo) -> some View {
        if info.id != rows.first?.id { Divider().overlay(Theme.Palette.separator) }
        row(info)
    }

    /// #471: the design system's ONE section-header treatment, which until now
    /// had zero call sites while five views hand-rolled their own small-caps
    /// label. This one was caption2 / tertiary / no tracking; the component is
    /// captionStrong / secondary / 0.6 and uppercases through `textCase`, so the
    /// string is passed as written.
    /// #471 was: an HStack + `.uppercased()` + `.font(.caption2)`, with the
    /// busy spinner beside the title; it rides with the + button now, which is
    /// the only place `OlcSectionHeader` offers and the end of the row the
    /// spinner's work belongs to anyway.
    // boc #490
    // #490 was: uppercase OlcSectionHeader and a caption-sized plus action.
    private var protocolsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s2) {
                SignalSectionHeader(L10n.protocolsSectionHeader.localized())
                Spacer(minLength: Theme.Metrics.s2)
                protocolHeaderActions
            }
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                SignalSectionHeader(L10n.protocolsSectionHeader.localized())
                protocolHeaderActions
            }
        }
    }

    private var protocolHeaderActions: some View {
        HStack(spacing: Theme.Metrics.s2) {
            if rowsBusy || listing == .loading { ProgressView().controlSize(.small) } // #490
            if canAddProtocol { addProtocolButton }
        }
    }
    // eoc #490

    private var addProtocolButton: some View {
        Button(action: onAddProtocol) {
            Label(L10n.addProtocolAction.localized(), systemImage: "plus.circle")
                .font(Theme.Typography.label) // #490 was: caption; actions need a readable label.
                .frame(minHeight: Theme.Metrics.controlHeight)
                .contentShape(Rectangle())
        }
        .disabled(actionsDisabled)
    }

    // MARK: 4 — what do I do next (#471: ONE filled button)

    // #471 was: `metricsBlock` (`ServerMetricsGrid`, deleted with this block)
    // sat here, and `actions` wrapped `quickRow` — a full-width grey "Container
    // logs" — above the primary button. A healthy card therefore ended in THREE
    // action treatments: a grey full-width button, a RED full-width button, a
    // hairline, and a tiny grey caption link. Two now, and the loud one is the
    // only one the card is actually offering.

    private var actions: some View {
        OlcButton(primary.title, systemImage: primary.systemImage,
                  role: primary.role, isBusy: primary.isBusy,
                  fillWidth: true, action: onPrimary)
            .disabled(actionsDisabled && !primary.isBusy)
    }

    // MARK: 5 — everything else (#459)

    /// #459: the way to the rare and the destructive. Eleven ⋯ items became one
    /// row: a push whose `Form` can give every destructive verb a sentence
    /// saying what it destroys — which a `Menu` cannot render at all. That is
    /// why "Wipe all olcrtc data from server" used to sit in a scrolling list
    /// with nothing but its own name to warn you.
    /// #471 was: a `Divider` above a lone caption-weight "Manage server ›" at
    /// 32pt — the least visible thing on the card, under the most visible. The
    /// two links share one 44pt row at the control step now, which is where the
    /// frequent verb (Logs) lands after losing its button.
    private var manageRow: some View {
        // #490 was: a fixed HStack; long localized actions now wrap vertically.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Metrics.s2) {
                logsButton
                Spacer(minLength: Theme.Metrics.s2)
                manageButton
            }
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                logsButton
                manageButton
            }
        }
    }

    @ViewBuilder
    private var logsButton: some View {
        if canOpenLogs {
            linkButton(L10n.logsTitle.localized(), chevron: false, action: onLogs)
        }
    }

    private var manageButton: some View {
        linkButton(L10n.vpsManageServer.localized(), chevron: true, action: onManage)
    }

    /// #471: one treatment for both links — accent, control step, a 44pt tap
    /// target. `contentShape` is what makes the whole 44pt tappable rather than
    /// just the glyphs inside it.
    private func linkButton(_ title: String, chevron: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Metrics.s1) {
                Text(title)
                if chevron { Image(systemName: "chevron.right") }
            }
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Signal.stroke) // #490: shared Signal action accent.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(actionsDisabled)
    }
}

// #471 was: `ServerMetricsGrid` (#458) — PING / DISK / RAM / UP as a 2x2 grid
// of uppercase tracked labels over body-size monospaced semibold values, ~85
// lines of layout defending four readings against truncation inside a ~150pt
// column.
//
// #458's four rules are not regressed, they are made unnecessary: nothing has
// to fit a narrow column any more. Disk / RAM / uptime are ONE caption under
// the address (`machineCaption`), a single `Text` with
// `fixedSize(horizontal: false, vertical: true)` and no `minimumScaleFactor` —
// it wraps rather than shrinks, which is rule 3 restated for a line instead of
// a cell. All four readings also exist as full-width, label-left/value-right
// rows on the Manage screen (`ServerMachineStats`,
// App/Views/ServerAdvancedView.swift), where a Form row is the width of the
// phone and the value keeps its `lineLimit(1)` because a wrapped number is a
// lie. `ServersView.shortUsage` / `shortRAM` / `shortUptime` are untouched —
// `VPSStatFormattingTests` pins them by name, and rule 4 (a value that is <= 9
// characters by construction) is why the caption fits at all.
