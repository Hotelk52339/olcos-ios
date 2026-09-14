import SwiftUI

// boc #490
// #490 was: default Form headers and surfaces. Signal uses shared sentence-case
// section headers, readable native rows and consistent sage action chrome.
// All fields, bindings, validation, secrets and submit/lifecycle methods remain.
// eoc #490

// MARK: - InstallOptionsView
//
// Sheet shown before "Install" runs SSH. The user picks carrier,
// transport and a room ID. Compatibility reference is
// in the Servers tab (always visible), not here.
//
// #258: carrier / transport use OlcChipPicker; the confirm action is a single
// full-width OlcButton(.primary) footer, with one close (✕) control.
//
// #452: multi-carrier install. The existing form is the PRIMARY protocol; a new
// "Additional protocols" section lets the user co-install the other carriers on
// the same server (sibling containers sharing one key — see scripts/add-carrier.sh).
// The sheet is also reused by the host card's "Add protocol" flow via
// `singleOnly` + `limitToCarriers` (extras hidden, carriers restricted to the
// ones not yet on the server).

struct InstallOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var carrier   : String
    @State private var transport : String
    @State private var roomID    = ""
    // #256: Jitsi rendezvous base URL — editable, pre-filled with the shared
    // default so users can point at their own instance. Only sent for jitsi.
    @State private var jitsiBaseURL = AppConstants.defaultJitsiBaseURL

    // SEI channel params — visible only when transport == "seichannel"
    @State private var seiFPS  : Int = 30
    @State private var seiBatch: Int = 10
    @State private var seiFrag : Int = 1200
    @State private var seiACK  : Int = 1

    // #436: wbstream account token (auth.token) — visible only for wbstream.
    @State private var wbToken = ""

    // boc #452: additional-protocol drafts, keyed by carrier id. Presence with
    // `enabled` drives the inline sub-form. Extras deliberately reuse the
    // server-side SEI defaults (30/10/1200/1 == OlcrtcConnection's own) instead
    // of adding four steppers per extra carrier — the sheet stays scannable and
    // the tuning remains editable per-connection afterwards.
    private struct ExtraDraft {
        var enabled = false
        var transport: String
        var roomID = ""
        var jitsiBaseURL = AppConstants.defaultJitsiBaseURL
        var wbToken = ""
    }
    @State private var extras: [String: ExtraDraft] = [:]

    /// Reuse mode (host card "Add protocol"): restrict the carrier chips to the
    /// providers not yet installed on the server. nil = the full matrix list.
    private let limitToCarriers: [String]?
    /// Reuse mode: hide the extras section — the sheet returns exactly ONE
    /// InstallOptions (extras array is empty).
    private let singleOnly: Bool
    // eoc #452

    // #452 was: `let onConfirm: (InstallOptions) -> Void` — now also returns the
    // additional-protocol options (empty for a single-protocol confirm).
    let onConfirm: (_ primary: InstallOptions, _ extras: [InstallOptions]) -> Void

    // boc #452: explicit init (the private stored properties above kill the
    // memberwise one). Seeds the carrier from the restricted list when present.
    init(limitToCarriers: [String]? = nil,
         singleOnly: Bool = false,
         onConfirm: @escaping (_ primary: InstallOptions, _ extras: [InstallOptions]) -> Void) {
        self.limitToCarriers = limitToCarriers
        self.singleOnly = singleOnly
        self.onConfirm = onConfirm
        let first = limitToCarriers?.first ?? "telemost"
        _carrier   = State(initialValue: first)
        _transport = State(initialValue: CarrierTransportMatrix.defaultTransport(for: first))
    }

    /// Carriers offered by the primary chips (restricted in reuse mode).
    private var availableCarriers: [String] {
        limitToCarriers ?? CarrierTransportMatrix.carriers
    }

    /// Carriers offered as extras: everything except the current primary,
    /// in matrix order. Hidden entirely in singleOnly mode.
    private var extraCarriers: [String] {
        CarrierTransportMatrix.carriers.filter { $0 != carrier }
    }

    private var enabledExtraCarriers: [String] {
        extraCarriers.filter { extras[$0]?.enabled == true }
    }

    private func draft(_ c: String) -> ExtraDraft {
        extras[c] ?? ExtraDraft(transport: CarrierTransportMatrix.defaultTransport(for: c))
    }

    private func draftBinding(_ c: String) -> Binding<ExtraDraft> {
        Binding(get: { draft(c) }, set: { extras[c] = $0 })
    }

    private func extraIsValid(_ c: String) -> Bool {
        let d = draft(c)
        guard CarrierTransportMatrix.compat(carrier: c, transport: d.transport) != .fail else { return false }
        if CarrierTransportMatrix.requiresRoomID(carrier: c) {
            return !d.roomID.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }
    // eoc #452

    private var requiresRoomID: Bool { CarrierTransportMatrix.requiresRoomID(carrier: carrier) }

    private var canSubmit: Bool {
        // (audit) `!= .fail` is belt-and-braces: the ✗ chips are disabled and the
        // carrier onChange resets transport to the default, but a submit of a
        // combo the matrix marks broken must never install a dead server.
        (!requiresRoomID || !roomID.trimmingCharacters(in: .whitespaces).isEmpty)
            && CarrierTransportMatrix.compat(carrier: carrier, transport: transport) != .fail
            // #452: every enabled extra must be valid too.
            && enabledExtraCarriers.allSatisfy { extraIsValid($0) }
    }

    /// (audit) transport chips with the ✗ combos for the current carrier
    /// disabled (OlcOption.disabled) and the reason surfaced to VoiceOver.
    /// #452: parametrised by carrier so the extras sub-forms reuse it.
    // #470 was: the matrix restated inline here (and again in two other sheets),
    // which is why the test that "checked" it could only compare the copy with
    // itself. One helper on the matrix; the test now checks the matrix.
    private func transportOptions(for carrier: String) -> [OlcOption<String>] {
        CarrierTransportMatrix.transportOptions(for: carrier)
    }

    var body: some View {
        NavigationStack {
            Form {
                carrierSection
                transportSection
                roomIDSection
                jitsiSection
                wbTokenSection
                seiSection
                extrasSection   // #452
                defaultsInfoSection
            }
            // #452: reuse mode gets its own title + confirm label.
            .signalFormChrome() // #490 was: default grouped-form chrome.
            .navigationTitle((singleOnly ? L10n.addProtocolTitle : L10n.installTitle).localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: shared sheet chrome (✕ close + full-width primary footer).
            .olcSheet(confirm: (singleOnly ? L10n.addProtocolAction : L10n.actionInstall).localized(),
                      icon: singleOnly ? "plus.circle" : "arrow.down.app",
                      disabled: !canSubmit) { submit() }
        }
    }

    // MARK: Sections

    private var carrierSection: some View {
        // #455 (editorial): the carrier section used to be the ONE form section
        // with a title but no footer, while transport/room/jitsi/wb/sei all
        // explain themselves — so the app's FIRST and most important choice got
        // the least guidance. It now has a header + a footer that says which
        // carrier to pick for what (the `carrierChoiceFooter` string).
        Section {
            // #452 was: options from CarrierTransportMatrix.carriers — now the
            // (possibly restricted) availableCarriers.
            // #490 was: OlcChipPicker; same options/bindings, native Signal rows.
            ServerSignalOptions(selection: $carrier,
                          options: availableCarriers.map { ($0, CarrierTransportMatrix.carrierLabel($0)) })
                .onChange(of: carrier) { _, c in
                    transport = CarrierTransportMatrix.defaultTransport(for: c)
                    // #452: the new primary can't also be an extra.
                    extras[c] = nil
                }
        } header: {
            SignalSectionHeader(L10n.sectionCarrier.localized())
        } footer: {
            // #471: B9 — a Form footer already renders at the caption step;
            // `.caption2` only pushed it BELOW the scale. was: .font(.caption2)
            Text(L10n.carrierChoiceFooter.localized())
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    private var transportSection: some View {
        Section {
            // (audit) options carry disabled+reason for the ✗ combos.
            // #490 was: OlcChipPicker; same options/bindings, native Signal rows.
            ServerSignalOptions(selection: $transport, options: transportOptions(for: carrier))
                .onChange(of: transport) { _, newTransport in
                    if newTransport != "seichannel" {
                        seiFPS = 30; seiBatch = 10; seiFrag = 1200; seiACK = 1
                    }
                }
        } header: {
            SignalSectionHeader(L10n.transportSectionHeader.localized())
        } footer: {
            // #457: the footer is empty for every transport but videochannel now
            // that the compatibility sentence is gone — render nothing rather
            // than an empty Text that still reserves footer space.
            if !transportFooter.isEmpty {
                Text(transportFooter)   // #471: B9 — a Form footer is already a caption
            }
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    /// #456: the app already knows the last room used with this carrier — offer
    /// it instead of making the user go and find it again (requirement 8). Shown
    /// only while the field is empty, so it never fights what the user typed.
    @ViewBuilder
    private func roomSuggestion(carrier: String, into binding: Binding<String>) -> some View {
        if binding.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty,
           let last = RoomMemory.lastRoom(forCarrier: carrier) {
            Button(L10n.roomIDLastUsed_fmt.formatted(last)) { binding.wrappedValue = last }
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption)
                .foregroundStyle(Theme.Signal.stroke) // #490: Signal action tint.
        }
    }

    @ViewBuilder
    private var roomIDSection: some View {
        if requiresRoomID {
            Section {
                TextField(L10n.fieldRoomID.localized(), text: $roomID)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                roomSuggestion(carrier: carrier, into: $roomID)   // #456
            } header: {
                SignalSectionHeader(L10n.roomIDSectionHeader.localized())
            } footer: {
                // #471: B9 — a Form footer is already a caption. was: .font(.caption2)
                Text(roomFooter)
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        } else {
            Section {
                Label(L10n.roomIDAutoGenHint.localized(),
                      systemImage: "wand.and.stars")
                    .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        }
    }

    // #256: only Jitsi has a user-pickable rendezvous instance (Telemost/WBStream
    // use fixed backends). Shown for jitsi so users aren't silently funnelled onto
    // the shared public default.
    @ViewBuilder
    private var jitsiSection: some View {
        if carrier == "jitsi" {
            Section {
                TextField(L10n.fieldJitsiURL.localized(), text: $jitsiBaseURL)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            } header: {
                SignalSectionHeader(L10n.jitsiServerHeader.localized())
            } footer: {
                // #471: B9 — a Form footer is already a caption. was: .font(.caption2)
                Text(L10n.jitsiServerFooter.localized())
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        }
    }

    // #436: wbstream account token → server `auth.token`. Optional (empty = an
    // anonymous guest); needed for datachannel, which requires publish rights.
    // Masked, like other secret entry — the value goes to the server config and
    // the connection's Keychain, never to logs.
    @ViewBuilder
    private var wbTokenSection: some View {
        if carrier == "wbstream" {
            Section {
                SecureField(L10n.wbTokenFieldLabel.localized(), text: $wbToken)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                SignalSectionHeader(L10n.wbTokenHeader.localized())
            } footer: {
                // #471: B9 — a Form footer is already a caption. was: .font(.caption2)
                Text(L10n.wbTokenFooter.localized())
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        }
    }

    @ViewBuilder
    private var seiSection: some View {
        if transport == "seichannel" {
            // (audit) was: literal "FPS:/Batch:/Frag:/ACK:" — RU users saw mixed
            // languages; the sei* keys already exist (used by AddConnectionView).
            Section {
                // #470 was: literal ranges here, different ones in the edit sheet, and
                // an ACK stepper of 0...10 for a value that is a millisecond timeout.
                Stepper("\(L10n.seiFpsLabel.localized()): \(seiFPS)", value: $seiFPS, in: SettingsStore.Defaults.seiFPSRange)
                Stepper("\(L10n.seiBatchLabel.localized()): \(seiBatch)", value: $seiBatch, in: SettingsStore.Defaults.seiBatchRange)
                Stepper("\(L10n.seiFragLabel.localized()): \(seiFrag)", value: $seiFrag, in: SettingsStore.Defaults.seiFragRange, step: 100)
                Stepper("\(L10n.seiAckLabel.localized()): \(seiACK)", value: $seiACK, in: SettingsStore.Defaults.seiACKRange, step: 100)
            } header: {
                SignalSectionHeader(L10n.seiSettingsHeader.localized())
            } footer: {
                // #471: B9 — a Form footer is already a caption. was: .font(.caption2)
                Text(L10n.seiSettingsFooter.localized())
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        }
    }

    // boc #452: additional-protocol toggles with inline sub-forms. Each enabled
    // extra mirrors the primary's fields (transport chips gated by the matrix,
    // room field / auto-generate hint, jitsi base, wb token) — but not the SEI
    // steppers (server defaults; see the ExtraDraft comment).
    @ViewBuilder
    private var extrasSection: some View {
        if !singleOnly {
            Section {
                ForEach(extraCarriers, id: \.self) { c in
                    extraRows(c)
                }
            } header: {
                SignalSectionHeader(L10n.installExtrasHeader.localized())
            } footer: {
                // #471: B9 — a Form footer is already a caption. was: .font(.caption2)
                Text(L10n.installExtrasFooter.localized())
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        }
    }

    @ViewBuilder
    private func extraRows(_ c: String) -> some View {
        let binding = draftBinding(c)
        Toggle(L10n.installExtraToggle_fmt.formatted(CarrierTransportMatrix.carrierLabel(c)),
               isOn: binding.enabled)
        if draft(c).enabled {
            // #490 was: OlcChipPicker; same options/bindings, native Signal rows.
            ServerSignalOptions(selection: binding.transport, options: transportOptions(for: c))
            // #457 was: `Text(extraCompat(c))` — the ★/⚠/✗ compatibility caption.
            // Deleted with the compatibility table: "working with X is uncertain"
            // and "no compatibility data for X" are judgements the app has not
            // measured, which is the same disease as an unearned green dot, in
            // words. The only surviving use of the matrix here is the SILENT
            // gate: `transportOptions(for:)` disables a `.fail` combo outright.
            extraRoomFields(c, binding: binding)
            extraJitsiFields(c, binding: binding)
            extraWbTokenFields(c, binding: binding)
        }
    }

    /// #452/#457: room entry for one extra protocol. Split out so `extraRows`
    /// stays a flat, cheap ViewBuilder (this sheet feeds a Form that is already
    /// several conditional sections deep).
    @ViewBuilder
    private func extraRoomFields(_ c: String, binding: Binding<ExtraDraft>) -> some View {
        if CarrierTransportMatrix.requiresRoomID(carrier: c) {
            TextField(L10n.fieldRoomID.localized(), text: binding.roomID)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            roomSuggestion(carrier: c, into: binding.roomID)   // #456
        } else {
            Label(L10n.roomIDAutoGenHint.localized(), systemImage: "wand.and.stars")
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// #457: the extras' Jitsi field had NO caption while the primary's identical
    /// field carries `jitsiServerFooter` ("shared public instance — point at your
    /// own…"). Same field, same consequence, so: same sentence. A `Form` section
    /// footer belongs to the whole section, and this one holds every extra, so
    /// the caption rides directly under its own field.
    @ViewBuilder
    private func extraJitsiFields(_ c: String, binding: Binding<ExtraDraft>) -> some View {
        if c == "jitsi" {
            TextField(L10n.fieldJitsiURL.localized(), text: binding.jitsiBaseURL)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Text(L10n.jitsiServerFooter.localized())
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// #457: same gap, same fix — the extras' wbstream token field is the one
    /// place a missing token silently produces a dead datachannel protocol, and
    /// it was the one place that did not say so. Reuses `wbTokenFooter`.
    @ViewBuilder
    private func extraWbTokenFields(_ c: String, binding: Binding<ExtraDraft>) -> some View {
        if c == "wbstream" {
            SecureField(L10n.wbTokenFieldLabel.localized(), text: binding.wbToken)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Text(L10n.wbTokenFooter.localized())
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    // eoc #452

    private var defaultsInfoSection: some View {
        Section {
            // #470: in Add-protocol mode (`singleOnly`) the sibling SHARES the
            // primary's key (scripts/add-carrier.sh) — "key … auto-generated" was
            // untrue there. #470 was: `Text(L10n.carrierFooter.localized())`.
            Text((singleOnly ? L10n.carrierFooterSharedKey : L10n.carrierFooter).localized())
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    // MARK: Logic

    private func submit() {
        // Telemost shows room IDs with spaces ("3528 5410 1234") for readability;
        // the API form has no spaces. Strip them so users can paste either form.
        let cleanedRoom = roomID
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        // Never send an empty OLCRTC_JITSI_URL (srv.sh's `:-` default only fills
        // an *unset* var, not an empty one) — fall back to the shared default.
        let cleanedJitsi = jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = InstallOptions(
            carrier:      carrier,
            transport:    transport,
            roomID:       requiresRoomID ? cleanedRoom : "",
            jitsiBaseURL: cleanedJitsi.isEmpty ? AppConstants.defaultJitsiBaseURL : cleanedJitsi,
            seiFPS:       seiFPS,
            seiBatch:     seiBatch,
            seiFrag:      seiFrag,
            seiACK:       seiACK,
            wbToken:      carrier == "wbstream" ? wbToken.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        )
        // boc #452: extras — same cleaning rules as the primary; SEI stays on
        // defaults (see ExtraDraft). Order follows the matrix's carriers list.
        let extraOptions: [InstallOptions] = singleOnly ? [] : enabledExtraCarriers.map { c in
            let d = draft(c)
            let room = d.roomID.components(separatedBy: .whitespacesAndNewlines).joined()
            let jitsi = d.jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return InstallOptions(
                carrier:      c,
                transport:    d.transport,
                roomID:       CarrierTransportMatrix.requiresRoomID(carrier: c) ? room : "",
                jitsiBaseURL: jitsi.isEmpty ? AppConstants.defaultJitsiBaseURL : jitsi,
                wbToken:      c == "wbstream" ? d.wbToken.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            )
        }
        onConfirm(primary, extraOptions)
        // eoc #452
        dismiss()
    }

    // MARK: Footer helpers

    /// #457 was: a `compat` sentence built from the compatibility table
    /// (`matrixRecommended_fmt` / `matrixWorks_fmt` / `matrixQuestion_fmt` /
    /// `matrixFail_fmt` / `matrixUnknown_fmt`), prepended to everything below.
    /// The table is gone: "★ recommended", "⚠ uncertain" and "no data" are
    /// verdicts from a lab run at pin time, presented as if they described the
    /// carriers today. What survives is the SILENT gate — `transportOptions(for:)`
    /// disables a `.fail` combo so an impossible install cannot be submitted.
    private var transportFooter: String {
        // #097 was: the warning also covered seichannel — stale since the install
        // sheet gained the SEI steppers (seiSection → installEnv → OLCRTC_SEI_*).
        // `vp8channel` tunes via the Settings sliders, `seichannel` via the
        // steppers above; only `videochannel` still installs with the server-side
        // defaults from scripts/srv.sh (OLCRTC_VIDEO_* deliberately has no UI —
        // #097 decision: ten niche knobs aren't worth the sheet sprawl).
        // #470 was: `.formatted(transport)` — the raw id ("videochannel") in user copy.
        transport == "videochannel"
            ? L10n.transportUsesServerDefaults_fmt.formatted(CarrierTransportMatrix.transportLabel(transport))
            : ""
    }

    private var roomFooter: String {
        switch carrier {
        case "telemost": return L10n.roomIDTelemostHint.localized()
        case "wbstream": return L10n.roomIDWbstreamHint.localized()
        default:         return ""
        }
    }

    // #457 was: `extraCompat(_:)` — the same ★/⚠/✗ compatibility sentence for an
    // extra protocol. Deleted with the table (see `transportFooter`); the extras
    // keep the hard `.fail` gate through `transportOptions(for:)`.
}
