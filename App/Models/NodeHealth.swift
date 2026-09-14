import SwiftUI   // for OlcStatusTone (defined in App/UI/DesignSystem.swift)

// MARK: - NodeHealth (#456)
//
// #456: the ONE health vocabulary. Before this file the app had three unrelated
// answers to "is this node OK": podman `Up` (green dot on Manage VPS), a
// view-local `@State` ms-pill on Connections, and the live tunnel's
// `verifyTunnel` verdict — and only the last one was evidence.
//
// The evidence ladder encoded below:
//   • podman "Up"  = the process exists                       → proves NOTHING
//   • checkReady   = WebRTC/smux handshake completed          → amber at best
//   • ping         = HTTP 2xx came back through the node's
//                    OWN SOCKS listener                       → the only green
//
// Every value here is measured, timestamped and persisted; `HealthDisplay` is
// the only thing views render, and it grants green ONLY inside
// `HealthPolicy.freshSeconds`. Ownership + persistence live in
// `HealthCoordinator` (App/Services/HealthCoordinator.swift).

/// #456: what a probe PROVED about one node. Persisted as a raw String (not a
/// Codable enum) so an unrecognised future value decodes to `.unknown` instead
/// of failing the whole map — the repo's decodeIfPresent-only evolution rule.
enum NodeHealthKind: String, Codable, Sendable {
    case working       // end-to-end proof: Ping got HTTP 2xx through this node's SOCKS,
                       // or the LIVE tunnel's verifyTunnel returned 200. The only green.
    case handshake     // checkReady only: transport reached ready, data path UNPROVEN.
    case broken        // a probe ran and failed for a NODE-SPECIFIC reason.
    case inconclusive  // we could NOT check (offline / VPS unreachable / VPN active).
                       // NEVER render this as failure — requirement 2.
    case unknown       // decoded from an unrecognised raw value.
}

/// #456: one persisted verification result. No secrets: rtt, dates, a stable
/// reason CODE and a short redacted engineering detail. The human sentence is
/// derived at display time via L10n (never cached — AGENTS.md).
struct NodeHealth: Codable, Equatable, Sendable {
    var kind: String            // NodeHealthKind.rawValue
    var checkedAt: Date
    var rttMs: Int?             // set only for .working from a Ping
    var reason: String?         // HealthReason.rawValue (nil for .working)
    var detail: String?         // <=200 chars, LogStore.redactSecrets'd, engineering only
    var source: String?         // "probe" | "live" | "op"

    var resolvedKind: NodeHealthKind { NodeHealthKind(rawValue: kind) ?? .unknown }
    var resolvedReason: HealthReason { HealthReason(rawValue: reason ?? "") ?? .unknown }

    init(kind: NodeHealthKind, checkedAt: Date = Date(), rttMs: Int? = nil,
         reason: HealthReason? = nil, detail: String? = nil, source: String) {
        self.kind = kind.rawValue
        self.checkedAt = checkedAt
        self.rttMs = rttMs
        self.reason = reason?.rawValue
        self.detail = detail.map { String($0.prefix(200)) }
        self.source = source
    }
}

/// #456: staleness + cost policy. ONE place, so no view invents a threshold.
enum HealthPolicy {
    /// A `.working` result is a PRESENT-TENSE claim (green) only inside this window.
    static let freshSeconds:      TimeInterval = 300      // 5 min
    /// Past this, the verdict is history only — rendered as `.stale`.
    static let staleSeconds:      TimeInterval = 1800     // 30 min
    /// Debounce: never re-probe a node checked this recently unless the user forced it.
    static let minRecheckSeconds: TimeInterval = 120      // 2 min
    /// Per-probe budget. NEVER ride SettingsStore.startTimeoutSeconds (60 s default):
    /// a hung carrier would cost a full minute × N nodes, sequentially.
    static let probeTimeoutMs:    Int = 20_000
    /// Cap on ONE automatic (non-user-initiated) sweep.
    static let autoSweepMaxNodes: Int = 6
    /// Entries older than this are dropped on load; the map is also capped.
    static let forgetSeconds:     TimeInterval = 60 * 60 * 24 * 30   // 30 days
    static let maxEntries:        Int = 200
}

/// #456: the ONE thing views render. Derived, never stored.
enum HealthDisplay: Equatable, Sendable {
    case never                                            // no probe on record
    case checking                                         // a probe is in flight NOW
    case verified(ms: Int?, age: TimeInterval)            // .working, age < freshSeconds  → GREEN
    case fading(ms: Int?, age: TimeInterval)              // .working, fresh…stale         → neutral, past tense
    case handshakeOnly(age: TimeInterval)                 // .handshake                    → amber
    case broken(HealthReason, age: TimeInterval)          // .broken                       → red
    case inconclusive(HealthReason, age: TimeInterval)    // .inconclusive                 → GREY, not red
    case stale(age: TimeInterval)                         // anything older than staleSeconds

    /// The ONLY place green is granted in the whole app.
    var isVerified: Bool { if case .verified = self { return true }; return false }
    var isChecking: Bool { self == .checking }

    var tone: OlcStatusTone {
        switch self {
        case .verified:                       return .ok        // green — earned
        case .checking:                       return .progress
        case .handshakeOnly:                  return .warn
        case .broken:                         return .error
        case .never, .fading, .inconclusive, .stale:
                                              return .unknown   // grey = we do not know
        }
    }

    /// Localised at the point of use (never cached).
    var title: String {
        switch self {
        case .never:            return L10n.healthNeverChecked.localized()
        case .checking:         return L10n.healthChecking.localized()
        case .verified:         return L10n.healthVerified.localized()
        case .fading:           return L10n.healthFading.localized()
        case .handshakeOnly:    return L10n.healthHandshake.localized()
        case .broken(let r, _): return r.headline
        case .inconclusive:     return L10n.healthInconclusive.localized()
        case .stale:            return L10n.healthStale.localized()
        }
    }

    // boc #459: every sentence here takes `HealthAge.phrase`, which carries its
    // own "ago"/«назад». The format strings lost the preposition they used to
    // append, because appending one to "just now" read "Verified just now ago"
    // («Проверено только что назад») three times on one screen.
    var subtitle: String {
        switch self {
        case .never:      return L10n.healthNeverCheckedHint.localized()
        case .checking:   return L10n.healthCheckingHint.localized()
        case .verified(let ms, let age), .fading(let ms, let age):
            // #459 was: HealthAge.label(age) + "Verified %@ ago · %d ms"
            let a = HealthAge.phrase(age)
            if let ms { return L10n.healthVerifiedHint_fmt.formatted(a, ms) }
            return L10n.healthVerifiedNoRTTHint_fmt.formatted(a)
        case .handshakeOnly(let age):
            // #459 was: HealthAge.label(age) + "Joined the room %@ ago, but…"
            return L10n.healthHandshakeHint_fmt.formatted(HealthAge.phrase(age))
        case .broken(let r, let age), .inconclusive(let r, let age):
            // #459 was: HealthAge.label(age) + "checked %@ ago"
            return "\(r.message) · \(L10n.healthCheckedAgo_fmt.formatted(HealthAge.phrase(age)))"
        case .stale(let age):
            // #459 was: HealthAge.label(age) + "Last checked %@ ago — …"
            return L10n.healthStaleHint_fmt.formatted(HealthAge.phrase(age))
        }
    }
    // eoc #459

    /// Short text for `OlcHealthChip` — "48 ms · 2m", "not checked", "failed 2 min ago".
    // boc #459: a chip takes `HealthAge.short` ONLY where a value beside the age
    // already supplies the grammar ("48 ms · 2m"); a chip that reads as a
    // sentence fragment ("worked …", "failed …", "last seen …") takes
    // `HealthAge.phrase` instead, so nothing has to append "ago" to it.
    var chipLabel: String {
        switch self {
        case .never:        return L10n.healthChipNever.localized()
        case .checking:     return ""                                   // chip shows a spinner
        // #456 (audit fix) was: one shared case for .verified and .fading, so
        // "working" and "worked a while ago" rendered the SAME words and were
        // told apart by colour alone — the exact failure this vocabulary exists
        // to prevent. `.fading` now says it in the past tense.
        case .verified(let ms, let age):
            let a = HealthAge.short(age)                                // #459 was: .label(age)
            // #470: the unit goes through `healthLatencyMs_fmt` ("%d ms" / "%d мс"),
            // the key the Diagnostics latency row prints — a Russian chip used to
            // read "215 ms · 2 мин" two cards above a row that said "215 мс".
            // #470 was: return ms.map { "\($0) ms · \(a)" } ?? a
            return ms.map { "\(L10n.healthLatencyMs_fmt.formatted($0)) · \(a)" } ?? a
        case .fading(let ms, let age):
            let a = HealthAge.short(age)                                // #459 was: .label(age)
            // #470 was: L10n.healthChipFaded_fmt.formatted("\($0) ms", a)
            return ms.map { L10n.healthChipFaded_fmt.formatted(L10n.healthLatencyMs_fmt.formatted($0), a) }
                // #459: "worked %@" — the string no longer appends "ago" itself.
                ?? L10n.healthChipFadedNoRTT_fmt.formatted(HealthAge.phrase(age))
        case .handshakeOnly(let age): return L10n.healthChipHandshake_fmt.formatted(HealthAge.short(age))   // #459
        // #459 was: "failed %@ ago" + .label → "failed just now ago".
        case .broken(_, let age):     return L10n.healthChipFailed_fmt.formatted(HealthAge.phrase(age))
        case .inconclusive:           return L10n.healthChipUnchecked.localized()
        // #459 was: "%@ old" + .label → "just now old". `.stale` is only reached
        // past HealthPolicy.staleSeconds, so "last seen 3 h ago" is always exact.
        // #470: exact in TIME, not in kind — `HealthCoordinator.display` files
        // EVERY kind as `.stale` past staleSeconds, so a key mismatch from 45 min
        // ago read "last seen 45 min ago", i.e. "it worked then". The key's text
        // is "checked %@" now (L10nTable), true of a stale failure and a stale
        // success alike; Review470Chunk4Tests pins that it never says "seen".
        case .stale(let age):         return L10n.healthChipStale_fmt.formatted(HealthAge.phrase(age))
        }
    }
    // eoc #459

    /// What the user should DO next; nil when there is nothing to offer.
    var suggestedAction: HealthAction? {
        switch self {
        case .broken(let r, _), .inconclusive(let r, _): return r.action
        case .never, .stale:                             return .verify
        default:                                         return nil
        }
    }
}

/// #456: compact relative age. Pure → unit-tested.
// boc #459: split in two, and `label` deliberately RENAMED away so that every
// call site becomes a compile error instead of a silent grammar bug.
// #459 was: static func label(_:) → "just now" / "%dm" / "%dh" / "%dd", used
// both inside sentences that appended "ago" (which produced "Verified just now
// ago" / «Проверено только что назад») and inside chips that did not.
enum HealthAge {
    /// #459: a SELF-CONTAINED relative phrase — "just now", "2 min ago",
    /// «только что», «2 мин назад». NOTHING may append a preposition to it:
    /// every format string that takes it must read "Verified %@", never
    /// "Verified %@ ago". Use this wherever the age sits inside a sentence.
    static func phrase(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60          { return L10n.ageJustNow.localized() }
        if s < 3600        { return L10n.ageMinutesAgo_fmt.formatted(Int(s / 60)) }
        if s < 86_400      { return L10n.ageHoursAgo_fmt.formatted(Int(s / 3600)) }
        return L10n.ageDaysAgo_fmt.formatted(Int(s / 86_400))
    }

    /// #459: a compact DURATION for an evidence chip, where the value beside it
    /// ("48 ms · 2m") already supplies the grammar. Never used in a sentence.
    static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60          { return L10n.ageNowShort.localized() }
        if s < 3600        { return L10n.ageMinutes_fmt.formatted(Int(s / 60)) }
        if s < 86_400      { return L10n.ageHours_fmt.formatted(Int(s / 3600)) }
        return L10n.ageDays_fmt.formatted(Int(s / 86_400))
    }
}
// eoc #459
