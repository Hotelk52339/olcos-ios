import SwiftUI

// boc #490
// #490 was: default Form headers and surfaces. Signal uses shared sentence-case
// section headers, readable native rows and consistent sage action chrome.
// All fields, bindings, validation, secrets and submit/lifecycle methods remain.
// eoc #490

// MARK: - ReconfigureOptionsView
//
// Sheet shown when the user taps "Change Room / Transport" in the server menu.
// Identical layout to InstallOptionsView but with a different title and
// confirm-button label — no apt-get / go build, just rewrite server.yaml and
// restart the existing container.
//
// #258: carrier / transport use OlcChipPicker; the confirm action is a single
// full-width OlcButton(.primary) footer, with one close (✕) control.
//
// #451: gained the jitsi base-URL field and the wbstream token field so a
// reconfigure can produce the same valid config an install does:
//   • jitsi — srv.sh prefixes a short room name with the base URL at install
//     time, but reconfigureScript seds `id:` verbatim, and master's jitsi
//     provider rejects a bare room name (ErrInvalidRoomURL). The prefixing
//     therefore happens CLIENT-side in submit() (reconfigureScript ignores
//     OLCRTC_JITSI_URL).
//   • wbstream — the token now flows into `auth.token` via reconfigureScript's
//     token sed (previously only the full install could set/clear it).
//
// #470: the jitsi base field never applied to an EXISTING install — the sheet is
// seeded with the full room URL srv.sh stores, and the prefixing above only fires
// for a bare name. `jitsiRoom(_:movedTo:)` now moves a full-URL room onto the
// edited instance in submit(). The transport footer also lost the ★/⚠ lab
// verdicts (and the raw carrier id they printed), mirroring InstallOptionsView #457.

struct ReconfigureOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var carrier   = "telemost"
    @State private var transport = CarrierTransportMatrix.defaultTransport(for: "telemost")
    @State private var roomID    = ""

    // boc #452: seed the form from the protocol row being reconfigured (the
    // host card now has one row per carrier). nil params keep the old blank
    // defaults, so the pre-#452 host-level entry point is unchanged.
    init(initialCarrier: String? = nil,
         initialTransport: String? = nil,
         initialRoom: String? = nil,
         // boc #456: these two used to seed BLANK. Confirming a wbstream
         // reconfigure therefore DELETED the server's auth.token (an empty
         // OLCRTC_WB_TOKEN removes the token line), and a self-hosted jitsi
         // instance silently reverted to the shared public default. Both values
         // are already on the record the row resolves to — seed them. Kept LAST
         // with defaults so every existing call site still compiles.
         initialWbToken: String? = nil,
         initialJitsiBase: String? = nil,
         // eoc #456
         onConfirm: @escaping (InstallOptions) -> Void) {
        self.onConfirm = onConfirm
        if let c = initialCarrier {
            _carrier   = State(initialValue: c)
            _transport = State(initialValue: initialTransport ?? CarrierTransportMatrix.defaultTransport(for: c))
        }
        if let r = initialRoom {
            _roomID = State(initialValue: r)
        }
        // boc #456
        if let t = initialWbToken, !t.isEmpty {
            _wbToken = State(initialValue: t)
        }
        if let j = initialJitsiBase, !j.isEmpty {
            _jitsiBaseURL = State(initialValue: j)
        }
        // eoc #456
    }
    // eoc #452
    // #451: jitsi rendezvous base URL — mirrors InstallOptionsView (#256);
    // used only to normalise a short jitsi room name in submit().
    @State private var jitsiBaseURL = AppConstants.defaultJitsiBaseURL
    // #451: wbstream account token (auth.token) — mirrors InstallOptionsView
    // (#436); visible only for wbstream. Empty = anonymous guest (any stored
    // token line is removed from the server config).
    @State private var wbToken = ""

    let onConfirm: (InstallOptions) -> Void

    private var requiresRoomID: Bool { CarrierTransportMatrix.requiresRoomID(carrier: carrier) }

    private var canSubmit: Bool {
        // (audit) `!= .fail` is belt-and-braces: the ✗ chips are disabled and the
        // carrier onChange resets transport to the default, but a submit of a
        // combo the matrix marks broken must never reconfigure to a dead server.
        (!requiresRoomID || !roomID.trimmingCharacters(in: .whitespaces).isEmpty)
            && CarrierTransportMatrix.compat(carrier: carrier, transport: transport) != .fail
    }

    /// (audit) transport chips with the ✗ combos for the current carrier
    /// disabled (OlcOption.disabled) and the reason surfaced to VoiceOver.
    private var transportOptions: [OlcOption<String>] {
        CarrierTransportMatrix.transports.map { t -> OlcOption<String> in
            let fails = CarrierTransportMatrix.compat(carrier: carrier, transport: t) == .fail
            return OlcOption(
                value: t,
                label: CarrierTransportMatrix.transportLabel(t),
                disabled: fails,
                disabledReason: fails
                    ? L10n.matrixFail_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier))
                    : nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                carrierSection
                transportSection
                roomIDSection
                jitsiSection
                wbTokenSection
                infoSection
            }
            .signalFormChrome() // #490 was: default grouped-form chrome.
            .navigationTitle(L10n.reconfigureTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: shared sheet chrome (✕ close + full-width primary footer).
            .olcSheet(confirm: L10n.actionChangeRoomTransport.localized(),
                      icon: "slider.horizontal.3", disabled: !canSubmit) { submit() }
        }
    }

    // MARK: Sections

    private var carrierSection: some View {
        // #455 (editorial): match InstallOptionsView — a header + a guidance
        // footer so the carrier choice is explained like every sibling section.
        Section {
            // #490 was: OlcChipPicker; same options/bindings, native Signal rows.
            ServerSignalOptions(selection: $carrier,
                          options: CarrierTransportMatrix.carriers.map { ($0, CarrierTransportMatrix.carrierLabel($0)) })
                .onChange(of: carrier) { _, c in
                    transport = CarrierTransportMatrix.defaultTransport(for: c)
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
            ServerSignalOptions(selection: $transport, options: transportOptions)
        } header: {
            SignalSectionHeader(L10n.transportSectionHeader.localized())
        } footer: {
            // #470: empty for every transport but videochannel now (see transportFooter).
            if !transportFooter.isEmpty {
                Text(transportFooter)   // #471: B9 — a Form footer is already a caption
            }
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    /// #456: offer the last room used with this carrier instead of asking for a
    /// value the app already has (requirement 8). Only while the field is empty.
    @ViewBuilder
    private var roomSuggestion: some View {
        if roomID.trimmingCharacters(in: .whitespaces).isEmpty,
           let last = RoomMemory.lastRoom(forCarrier: carrier) {
            Button(L10n.roomIDLastUsed_fmt.formatted(last)) { roomID = last }
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
                roomSuggestion   // #456
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

    // #451: mirrors InstallOptionsView.jitsiSection (#256) — the base a short
    // room name is prefixed with (client-side here, see submit()).
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

    // #451: mirrors InstallOptionsView.wbTokenSection (#436).
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

    private var infoSection: some View {
        Section {
            // #451: second line — reconfigure rewrites only provider/id/
            // transport (+ auth.token); it does NOT write vp8:/sei: tuning
            // blocks, so after a transport switch the server runs its engine
            // defaults (master overlays only keys present in the YAML).
            Text(L10n.reconfigureInfoFooter.localized() + "\n" +
                 L10n.reconfigureTransportTuningFooter.localized())
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    // MARK: Logic

    private func submit() {
        // Telemost shows room IDs with spaces ("3528 5410 1234") for readability;
        // the API form has no spaces. Strip them so users can paste either form.
        var cleanedRoom = roomID
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        // #451: normalise a short jitsi room name into the full URL the server
        // requires — the same rule srv.sh applies at install (base + "/" + name;
        // full http(s) URLs and host/room forms pass through verbatim).
        // reconfigureScript writes `id:` verbatim, so this must happen here.
        if carrier == "jitsi", !cleanedRoom.isEmpty,
           !cleanedRoom.contains("://"), !cleanedRoom.contains("/") {
            let trimmedBase = jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            var base = trimmedBase.isEmpty ? AppConstants.defaultJitsiBaseURL : trimmedBase
            while base.hasSuffix("/") { base.removeLast() }   // srv.sh: ${JITSI_BASE%/}
            cleanedRoom = base + "/" + cleanedRoom
        } else if carrier == "jitsi" {
            // #470: an existing install is seeded with the FULL room URL, so the
            // branch above never ran and the Jitsi-server field was a no-op —
            // move the room onto the edited instance instead.
            cleanedRoom = Self.jitsiRoom(cleanedRoom, movedTo: jitsiBaseURL)
        }
        let cleanedJitsi = jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfirm(InstallOptions(
            carrier:      carrier,
            transport:    transport,
            roomID:       requiresRoomID ? cleanedRoom : "",
            jitsiBaseURL: cleanedJitsi.isEmpty ? AppConstants.defaultJitsiBaseURL : cleanedJitsi,
            wbToken:      carrier == "wbstream" ? wbToken.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        ))
        dismiss()
    }

    /// #470: a jitsi room is stored as the FULL URL srv.sh writes
    /// ("https://host/room"), so editing the Jitsi-server field did nothing for
    /// an existing install. Moves a full-URL room onto `base` (scheme://host[:port],
    /// trailing slashes ignored), keeping the room's path. Anything else — a bare
    /// name, a host/room form, an empty base, the same instance — comes back
    /// unchanged. Pure → unit-tested (Tests/Review470Chunk2Tests.swift).
    static func jitsiRoom(_ room: String, movedTo base: String) -> String {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, room.contains("://"),
              let url = URL(string: room), let scheme = url.scheme,
              let host = url.host, !host.isEmpty else { return room }
        let hostPart = url.port.map { "\(host):\($0)" } ?? host
        if base == "\(scheme)://\(hostPart)" || base == hostPart { return room }
        return base + url.path + (url.query.map { "?\($0)" } ?? "")
    }

    // MARK: Footer helpers

    /// #470: mirrors InstallOptionsView.transportFooter (#457). The ★/⚠/"no data"
    /// sentence was a lab verdict at pin time presented as a measurement, and it
    /// printed the RAW carrier id ("★ Recommended for telemost.") where the install
    /// sheet showed «Яндекс Телемост». The silent `.fail` gate in
    /// `transportOptions` survives; the server-defaults note stays for
    /// videochannel only — a seichannel reconfigure's tuning reset is already
    /// stated by `reconfigureTransportTuningFooter` in the info section.
    // boc #470 was:
    //     let compat: String
    //     switch CarrierTransportMatrix.compat(carrier: carrier, transport: transport) {
    //     case .recommended: compat = L10n.matrixRecommended_fmt.formatted(carrier)
    //     case .ok:          compat = L10n.matrixWorks_fmt.formatted(carrier)
    //     case .question:    compat = L10n.matrixQuestion_fmt.formatted(carrier)
    //     case .fail:        compat = L10n.matrixFail_fmt.formatted(carrier)
    //     case .unknown:     compat = L10n.matrixUnknown_fmt.formatted(carrier)
    //     }
    //     if transport == "seichannel" || transport == "videochannel" {
    //         return compat + "\n" + L10n.transportUsesServerDefaults_fmt.formatted(transport)
    //     }
    //     return compat
    // eoc #470
    private var transportFooter: String {
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
}
