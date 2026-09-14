import SwiftUI

// #263: The single-source VPS display model + its pure reducer, moved out of
// ServersView (introduced in #258, reducer extracted in #259). The View drives
// these transitions; `HostDisplayTests` covers them. The "no status-jump"
// invariants live here:
//   • a probe result is the ONLY thing that sets the base (terminalBase),
//   • while running the card shows the PREVIOUS base, never the optimistic target,
//   • phases advance forward only (advanced), capped at the last milestone,
//   • a failure carries previousBase so Retry (retryBase) can restore it.

/// What the server IS. Set ONLY from a confirmed probe — never optimistically
/// mid-operation. Maps from `VPSReadinessState`.
enum HostBase: Equatable {
    case unknown, noPodman, noImage, imageReady, stopped, running

    init(_ r: VPSReadinessState) {
        switch r {
        case .noPodman:         self = .noPodman
        case .noImage:          self = .noImage
        case .imageReady:       self = .imageReady
        case .containerStopped: self = .stopped
        case .containerRunning: self = .running
        }
    }

    var hasContainer: Bool { self == .running || self == .stopped }

    var tone: OlcStatusTone {
        switch self {
        case .unknown, .noPodman:   return .unknown
        case .noImage:              return .progress   // amber — Podman ok, image not pulled
        // #456 was: .ok — green is now reserved for an end-to-end VERIFIED result;
        // podman "Up" only proves the process exists (the user's telemost container
        // was Up and green while its own logs read `traffic: in=0 out=0`), and
        // `.imageReady` means "nothing installed yet", which was never a success.
        case .imageReady, .running: return .unknown
        case .stopped:              return .warn
        }
    }
    var title: String {
        switch self {
        case .unknown:    return L10n.vpsTitleUnknown.localized()
        // #471 was: `vpsTitleReady` — the same title for "nothing is installed"
        // and "the image is built and ready", two different situations.
        case .noPodman:   return L10n.vpsTitleNothingInstalled.localized()
        case .noImage:    return L10n.vpsTitlePodmanReady.localized()
        case .imageReady: return L10n.vpsTitleReady.localized()
        case .stopped:    return L10n.vpsTitleStopped.localized()
        case .running:    return L10n.vpsTitleRunning.localized()
        }
    }
    var subtitle: String {
        switch self {
        case .unknown:    return L10n.vpsSubUnknown.localized()
        case .noPodman:   return L10n.vpsSubNoPodman.localized()
        case .noImage:    return L10n.vpsSubNoImage.localized()
        case .imageReady: return L10n.vpsSubImageReady.localized()
        case .stopped:    return L10n.vpsSubStopped.localized()
        case .running:    return L10n.vpsSubRunning.localized()
        }
    }
}

/// What we're DOING. `stepCount` sizes the progress-bar denominator (the live
/// provisioner message is the running subtitle); `target` is the nominal resolved
/// state used only when an op doesn't probe.
enum HostOp: Equatable {
    case check, install, start, stop, reconfigure, update, uninstall, deepUninstall, reboot

    var verb: String {
        switch self {
        case .check:         return L10n.vpsVerbChecking.localized()
        case .install:       return L10n.vpsVerbInstalling.localized()
        case .start:         return L10n.vpsVerbStarting.localized()
        case .stop:          return L10n.vpsVerbStopping.localized()
        case .reconfigure:   return L10n.vpsVerbReconfiguring.localized()
        case .update:        return L10n.vpsVerbUpdating.localized()
        case .uninstall:     return L10n.vpsVerbUninstalling.localized()
        case .deepUninstall: return L10n.vpsVerbDeepUninstalling.localized()
        case .reboot:        return L10n.vpsVerbRebooting.localized()
        }
    }

    /// Number of progress milestones — sizes the bar denominator only. The
    /// displayed running subtitle is the live (localized) provisioner message,
    /// not a fixed phase label, so individual step strings aren't needed.
    var stepCount: Int {
        switch self {
        case .check:  return 2
        case .install: return 5
        case .update: return 4
        case .start, .stop, .reconfigure, .uninstall, .deepUninstall, .reboot: return 3
        }
    }

    var target: HostBase? {
        switch self {
        case .check, .reboot:                          return nil      // keep previous base
        case .install, .start, .reconfigure, .update:  return .running
        case .stop:                                    return .stopped
        case .uninstall:                               return .imageReady
        case .deepUninstall:                           return .noPodman
        }
    }
}

/// The ONE display state. The card computes everything (status pill, progress bar,
/// primary button, menu) from this. `previousBase` rides along so Retry / a
/// no-probe success can restore without a second source.
enum HostDisplay: Equatable {
    case base(HostBase)
    case running(op: HostOp, phase: Int, note: String, previousBase: HostBase)
    case failed(op: HostOp, phase: String, message: String, previousBase: HostBase)
}

// MARK: - Reducer (pure — unit-tested in HostDisplayTests)

extension HostBase {
    /// Pre-probe seed for a never-probed host: a known container → `.stopped`
    /// (offer Start, never a mistaken reinstall); otherwise `.unknown` ("tap
    /// Check"). Never asserts `.running` without a probe.
    static func seed(lastContainerName: String?) -> HostBase {
        lastContainerName != nil ? .stopped : .unknown
    }
}

extension HostDisplay {
    /// The confirmed base under whatever is shown. Running / failed keep the base
    /// they started from — so the card never shows an optimistic state mid-op.
    var base: HostBase {
        switch self {
        case .base(let b):                return b
        case .running(_, _, _, let prev): return prev
        case .failed(_, _, _, let prev):  return prev
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Begin an operation from a confirmed base: phase 0, first milestone note.
    static func start(_ op: HostOp, from base: HostBase) -> HostDisplay {
        .running(op: op, phase: 0, note: L10n.vpsConnecting.localized(), previousBase: base)
    }

    /// Advance a running operation: phase forward only (capped at the last
    /// milestone) + the live note. Non-running states pass through unchanged.
    func advanced(note: String) -> HostDisplay {
        guard case .running(let op, let phase, _, let prev) = self else { return self }
        let next = min(phase + 1, max(op.stepCount - 1, 0))
        return .running(op: op, phase: next, note: note, previousBase: prev)
    }

    /// The ONE terminal base on success: the probe result wins; else the op's
    /// nominal target; else the base we started from. Only a real probe should
    /// pass a non-nil `probed`.
    static func terminalBase(op: HostOp, probed: HostBase?, previous: HostBase) -> HostBase {
        probed ?? op.target ?? previous
    }

    /// Terminal failure: keep the op + the note where it failed, carry the
    /// previous base for Retry. Non-running → unchanged.
    func failed(message: String) -> HostDisplay {
        guard case .running(let op, _, let note, let prev) = self else { return self }
        return .failed(op: op, phase: note, message: message, previousBase: prev)
    }

    /// What Retry restores before re-dispatching the op: the base under a failure.
    func retryBase() -> HostDisplay? {
        guard case .failed(_, _, _, let prev) = self else { return nil }
        return .base(prev)
    }
}

// MARK: - HostHeadline (#456)

/// #456: the ONE headline for a VPS card. Combines what SSH proved about the
/// HOST with what end-to-end probes proved about its PROTOCOLS. Pure → tested.
///
/// This replaces "the podman pill is the card's verdict". Podman status is
/// demoted to a clause of the headline's own subtitle; the headline answers the
/// only question the user actually has: *what is true right now, and what do I
/// do?*
/// #471 was: "…demoted to a caption LINE with its own age" — that line
/// (`ServerCardView.readStamp`) and the failure banner under it are deleted;
/// every fact they carried is an argument to `reduce` now, so the card states
/// its one claim exactly once.
enum HostHeadline: Equatable {
    /// An operation is running. Carries the op's VERB for the title AND the live
    /// provisioner note + step for the subtitle. #470: `step` is the 0-based
    /// `HostDisplay.running.phase` (capped at `stepCount - 1`); `subtitle`
    /// renders it 1-based, like the progress bar.
    /// #456 (audit fix) was: `case busy(String)` holding only the verb, so the
    /// pill rendered "Installing…" as its title and "Installing" as its subtitle
    /// — the same word twice — and the running commentary the user relies on to
    /// see progress (which the provisioner publishes continuously) was dropped.
    case busy(verb: String, note: String, step: Int, of: Int)
    /// The last operation failed: WHICH op, and its message.
    /// #456 (audit fix) was: `case opFailed(String)` (message only), so the title
    /// became a generic "Last action failed" and the user could no longer tell
    /// whether the install, the reconfigure or the uninstall was the thing that
    /// broke.
    case opFailed(verb: String, message: String)
    /// SSH / TCP said no. This is "couldn't check" — requirement 2 — and is NEVER
    /// rendered as stopped or failed, however old the last container reading is.
    case unreachable(age: TimeInterval?)
    /// Nothing has probed this host yet this launch — an honest blank, not a
    /// present-tense claim recycled from a persisted value.
    case notChecked
    /// #469: the last silent probe FAILED (SSH auth, host key, timeout). Grey —
    /// "could not check" is not a verdict about the server — but it names the
    /// reason instead of leaving "Checking the server…" on screen all session.
    case probeFailed(String)
    // boc #471: one claim, one age, one count. The card used to print the read
    // age a second time under the pill (`ServerCardView.readStamp`) and the
    // failing count a third time under that (`failureBanner`), so a host could
    // read "Working" with "1 of 2 protocols are not working" 8pt below it. Both
    // facts ride on the ONE headline now: an age belongs beside the claim it
    // dates, and the tally IS the claim.
    // #471 was: `case containerStopped` / `case noContainer(HostBase)` /
    // `case health(HealthDisplay)` — all three undated, the last uncounted.
    case containerStopped(age: TimeInterval?)
    case noContainer(HostBase, age: TimeInterval?)
    /// Nothing is in the way: the card shows the PROTOCOLS' measured verdict —
    /// how many of them a probe VERIFIED (the only route to green), out of how
    /// many, and how old the OLDEST of those readings is, so the age is true of
    /// every one of them.
    case health(HealthDisplay, verified: Int, total: Int, age: TimeInterval?)
    // eoc #471

    /// Precedence, strictly in this order:
    /// 1 running op · 2 failed op · 3 SSH/TCP said no ("couldn't check", NEVER
    /// "stopped") · 4 never probed this launch · 5 container stopped ·
    /// 6 nothing installed · 7 the protocols' measured verdict.
    static func reduce(display: HostDisplay,
                       reachable: Bool?,
                       lastProbeAge: TimeInterval?,
                       health: HealthDisplay,
                       probeError: String? = nil,   // #469
                       // boc #471: the protocol tally the card used to state
                       // twice — once as `failureBanner` ("1 of 2 protocols are
                       // not working") under a pill that said "Working", once
                       // inside the pill's own health sentence. ServersView
                       // counts only what a probe VERIFIED and dates it with the
                       // OLDEST of those readings. Defaults last, so every
                       // existing caller keeps the uncounted `.health` fallback.
                       verified: Int = 0,
                       total: Int = 0,
                       verifiedAge: TimeInterval? = nil) -> HostHeadline {   // eoc #471
        if case .running(let op, let phase, let note, _) = display {
            return .busy(verb: op.verb, note: note, step: phase, of: op.stepCount)   // #456
        }
        if case .failed(let op, _, let message, _) = display {
            return .opFailed(verb: op.verb, message: message)   // #456
        }
        // Before ANY container reading: an unreachable VPS tells us nothing about
        // the container, so a stale "stopped" must never surface as fact here.
        if reachable == false { return .unreachable(age: lastProbeAge) }
        // #469: a probe that threw is more informative than "not checked yet".
        if lastProbeAge == nil, let probeError { return .probeFailed(probeError) }
        if lastProbeAge == nil { return .notChecked }
        // #469 was: `.containerStopped` whenever the PRIMARY was stopped — the
        // base tracks only that container, so a host whose jitsi primary was
        // stopped while its telemost sibling carried a verified live tunnel
        // read "Server stopped · tap Start server". Measured, fresh evidence
        // that a protocol works outranks one container's podman state.
        // #471: the age rides with the state it dates (see `subtitle`), so the
        // card never needs a second line to say how old its claim is.
        if display.base == .stopped, !health.isVerified { return .containerStopped(age: lastProbeAge) }
        if !display.base.hasContainer { return .noContainer(display.base, age: lastProbeAge) }
        return .health(health, verified: verified, total: total, age: verifiedAge)
    }

    /// #471: measured evidence exists, but not for every protocol on the host.
    /// Pure, so `Design471ServersTests` can pin it. It only ever DOWNGRADES a
    /// green: a `.broken` or `.never` summary keeps its own verdict, because
    /// "partly working" would be an upgrade of a failure.
    static func isPartial(_ health: HealthDisplay, verified: Int, total: Int) -> Bool {
        health.isVerified && total > 0 && verified < total
    }

    var tone: OlcStatusTone {
        switch self {
        case .busy:             return .progress
        case .opFailed:         return .error
        // Grey, not red: "we could not check" is not a verdict about the server.
        case .unreachable:      return .unknown
        case .notChecked:       return .unknown
        case .probeFailed:      return .unknown   // #469
        case .containerStopped: return .warn
        case .noContainer(let b, _): return b.tone
        // #471: green survives only while EVERY protocol is verified. A card
        // reading "Working" above a dead sibling was the average hiding a known
        // failure — the job the deleted `failureBanner` did 8pt lower.
        case .health(let h, let v, let t, _):
            return Self.isPartial(h, verified: v, total: t) ? .warn : h.tone
        }
    }

    var title: String {
        switch self {
        case .busy(let verb, _, _, _): return "\(verb)…"
        // #456 (audit fix): name the operation that failed, not a generic sentence.
        case .opFailed(let verb, _):  return L10n.vpsOpFailed_fmt.formatted(verb)
        case .unreachable:        return L10n.vpsHeadlineUnreachable.localized()
        case .notChecked:         return L10n.vpsHeadlineNotChecked.localized()
        case .probeFailed:        return L10n.vpsHeadlineProbeFailed.localized()   // #469
        case .containerStopped:   return L10n.vpsHeadlineStopped.localized()
        case .noContainer(let b, _): return b.title
        // #471: "Working" and "not working" never share a card again.
        case .health(let h, let v, let t, _):
            return Self.isPartial(h, verified: v, total: t)
                ? L10n.healthPartlyWorking.localized() : h.title
        }
    }

    var subtitle: String {
        switch self {
        // #456 (audit fix): the live note plus "step n/total" — what the card
        // showed before the headline reducer existed.
        case .busy(_, let note, let step, let total):
            // #470: `step` is the 0-based phase while the bar draws
            // (phase + 1) / stepCount (`ServersView.statusBarFraction`), so the
            // pill read "0/3" over a third of a bar and topped out at "2/3"
            // under a full one. Same 1-based rendering as the bar (and as
            // LogsView's fetch phases).
            // #470 was: "\(step)/\(total)"
            let shown = min(step + 1, total)
            return note.isEmpty ? "\(shown)/\(total)" : "\(note) · \(shown)/\(total)"
        case .opFailed(_, let m): return m
        // boc #459 was: HealthAge.label($0) inside "SSH didn't answer (%@ ago)",
        // which rendered "SSH didn't answer (just now ago)". `phrase` carries its
        // own preposition, so the string is now "SSH didn't answer (%@)".
        case .unreachable(let age):
            return age.map { L10n.vpsHeadlineUnreachableHint_fmt.formatted(HealthAge.phrase($0)) }
                ?? L10n.vpsHeadlineUnreachableHintNever.localized()
        // eoc #459
        case .notChecked:         return L10n.vpsHeadlineNotCheckedHint.localized()
        case .probeFailed(let m): return m   // #469: the actual error, verbatim
        // boc #471: the read age, on the sentence it qualifies.
        // #471 was: `vpsHeadlineStoppedHint` / `b.subtitle`, undated, while the
        // card printed "read 2 min ago" on a line of its own directly below.
        case .containerStopped(let age):
            return age.map { L10n.vpsHeadlineStoppedHint_fmt.formatted(HealthAge.phrase($0)) }
                ?? L10n.vpsHeadlineStoppedHint.localized()
        case .noContainer(let b, let age):
            return age.map { "\(b.subtitle) · \(L10n.healthCheckedAgo_fmt.formatted(HealthAge.phrase($0)))" }
                ?? b.subtitle
        // #471: the tally IS the subtitle. Without a verified reading there is
        // no age to date one with, so the health vocabulary's own sentence
        // stands — it dates itself (App/Models/NodeHealth.swift).
        case .health(let h, let v, let t, let age):
            guard t > 0, let age else { return h.subtitle }
            return L10n.vpsHeadlineProtocolsVerified_fmt.formatted(v, t, HealthAge.phrase(age))
        // eoc #471
        }
    }
}
