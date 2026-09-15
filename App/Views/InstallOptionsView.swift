import SwiftUI

/// Protocol options sheet for an existing server: the "add missing protocols"
/// path (`singleOnly`) and the legacy full install. New servers go through
/// `AddServerFlowView`; this sheet shares its look and copy.
struct InstallOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var carrier: String
    @State private var transport: String
    @State private var roomID = ""
    @State private var jitsiBaseURL = AppConstants.defaultJitsiBaseURL

    @State private var seiFPS: Int = 30
    @State private var seiBatch: Int = 10
    @State private var seiFrag: Int = 1200
    @State private var seiACK: Int = 1

    @State private var wbToken = ""

    private struct ExtraDraft {
        var enabled = false
        var transport: String
        var roomID = ""
        var jitsiBaseURL = AppConstants.defaultJitsiBaseURL
        var wbToken = ""
    }
    @State private var extras: [String: ExtraDraft] = [:]

    private let limitToCarriers: [String]?
    private let singleOnly: Bool

    let onConfirm: (_ primary: InstallOptions, _ extras: [InstallOptions]) -> Void

    init(limitToCarriers: [String]? = nil,
         singleOnly: Bool = false,
         onConfirm: @escaping (_ primary: InstallOptions, _ extras: [InstallOptions]) -> Void) {
        self.limitToCarriers = limitToCarriers
        self.singleOnly = singleOnly
        self.onConfirm = onConfirm
        let first = limitToCarriers?.first ?? "jitsi"
        _carrier = State(initialValue: first)
        _transport = State(initialValue: CarrierTransportMatrix.defaultTransport(for: first))
    }

    // MARK: Derived

    private var availableCarriers: [String] {
        limitToCarriers ?? CarrierTransportMatrix.carriers
    }

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

    /// Jitsi accepts an empty room (the server generates one); the others need an ID.
    static func roomIsValid(carrier: String, roomID: String) -> Bool {
        carrier == "jitsi" || !roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func extraIsValid(_ c: String) -> Bool {
        let d = draft(c)
        return CarrierTransportMatrix.compat(carrier: c, transport: d.transport) != .fail
            && Self.roomIsValid(carrier: c, roomID: d.roomID)
    }

    private var canSubmit: Bool {
        Self.roomIsValid(carrier: carrier, roomID: roomID)
            && CarrierTransportMatrix.compat(carrier: carrier, transport: transport) != .fail
            && enabledExtraCarriers.allSatisfy { extraIsValid($0) }
    }

    // MARK: Body

    // Round 2 was: a ScrollView of OlcCards with uppercase OlcSectionHeaders —
    // a third look beside the Form-based Edit and Reconfigure sheets. The sheet
    // is now the same grouped Form (SignalSectionHeader rows, one pinned primary
    // action); every field is a FormField with a placeholder and a helper line.
    var body: some View {
        NavigationStack {
            Form {
                leadSection
                carrierSection
                transportSection(for: carrier, selection: $transport)
                roomSection(for: carrier, roomID: $roomID, jitsiBaseURL: $jitsiBaseURL, wbToken: $wbToken)
                if transport == "seichannel" { seiSection }
                if !singleOnly { extrasSections }
                footerSection
            }
            .signalFormChrome()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle((singleOnly ? L10n.addProtocolTitle : L10n.installTitle).localized())
            .navigationBarTitleDisplayMode(.inline)
            .olcSheet(confirm: (singleOnly ? L10n.addProtocolAction : L10n.actionInstall).localized(),
                      icon: singleOnly ? "plus.circle" : "arrow.down.app",
                      disabled: !canSubmit) { submit() }
        }
        .onChange(of: carrier) { _, c in
            transport = CarrierTransportMatrix.defaultTransport(for: c)
            extras[c] = nil
        }
        .onChange(of: transport) { _, t in
            if t != "seichannel" { seiFPS = 30; seiBatch = 10; seiFrag = 1200; seiACK = 1 }
        }
    }

    // MARK: Lead / footer

    /// The one-sentence purpose line, drawn as plain text on the ground (not a
    /// card row) so the first card is the first choice.
    private var leadSection: some View {
        Section {
            Text((singleOnly ? L10n.installOptionsLead : L10n.addFlowProtocolsLead).localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    private var footerSection: some View {
        Section {
            FormNote(text: (singleOnly ? L10n.carrierFooterSharedKey : L10n.carrierFooter).localized())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    // MARK: Carrier

    private var carrierSection: some View {
        Section {
            ForEach(availableCarriers, id: \.self) { c in
                carrierRow(c)
            }
        } header: {
            SignalSectionHeader(L10n.sectionCarrier.localized())
        }
        .signalFormRows()
    }

    private func carrierRow(_ c: String) -> some View {
        let selected = carrier == c
        return Button {
            Haptics.tap()
            withAnimation(.snappy) { carrier = c }
        } label: {
            HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    HStack(spacing: Theme.Metrics.s2) {
                        Text(CarrierTransportMatrix.carrierLabel(c))
                            .font(selected ? Theme.Typography.bodyStrong : Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if let badge = AddServerCarrierPlan.badge(for: c).title {
                            AddServerBadge(text: badge.localized(),
                                           tone: AddServerCarrierPlan.badge(for: c) == .recommended ? .ok : .unknown)
                        }
                        if c == "telemost" {
                            AddServerBadge(text: L10n.addFlowNeedsYandex.localized(), tone: .warn)
                        }
                    }
                    Text(AddServerCarrierPlan.descriptionKey(forCarrier: c).localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    // Round 2: the same selection tint as ServerSignalOptions (Reconfigure).
                    .foregroundStyle(selected ? Theme.Signal.stroke : Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Transport

    private func transportSection(for c: String, selection: Binding<String>) -> some View {
        let recommended = CarrierTransportMatrix.defaultTransport(for: c)
        return Section {
            ForEach(AddServerCarrierPlan.transportOptions(for: c), id: \.self) { t in
                transportRow(t, carrier: c, selected: selection.wrappedValue == t,
                             recommended: t == recommended) {
                    Haptics.tap()
                    selection.wrappedValue = t
                }
            }
        } header: {
            SignalSectionHeader(L10n.addFlowTransportFor_fmt.formatted(CarrierTransportMatrix.carrierLabel(c)))
        } footer: {
            if selection.wrappedValue == "videochannel" {
                Text(L10n.transportUsesServerDefaults_fmt.formatted(
                    CarrierTransportMatrix.transportLabel("videochannel")))
            }
        }
        .signalFormRows()
    }

    private func transportRow(_ t: String, carrier c: String, selected: Bool,
                              recommended: Bool, action: @escaping () -> Void) -> some View {
        let compat = CarrierTransportMatrix.compat(carrier: c, transport: t)
        return Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    HStack(spacing: Theme.Metrics.s2) {
                        Text(CarrierTransportMatrix.transportLabel(t))
                            .font(selected ? Theme.Typography.bodyStrong : Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if recommended {
                            AddServerBadge(text: L10n.addFlowBadgeRecommended.localized(), tone: .ok)
                        }
                    }
                    Text(AddServerCarrierPlan.descriptionKey(forTransport: t).localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if compat == .question {
                        // Round 2: the ⚠ verdict as a tinted note, not a bare glyph line.
                        FormNote(text: L10n.matrixQuestion_fmt.formatted(CarrierTransportMatrix.carrierLabel(c)),
                                 tone: .warn)
                    }
                }
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.Signal.stroke : Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Room

    /// Field label above the value, helper below — one FormField per input, with
    /// the same placeholders the Edit sheet uses (`roomIDPlaceholder`,
    /// `wbTokenPlaceholder`) instead of one example id beside blank fields.
    private func roomSection(for c: String, roomID: Binding<String>,
                             jitsiBaseURL: Binding<String>, wbToken: Binding<String>) -> some View {
        Section {
            switch c {
            case "jitsi":
                jitsiInstanceMenu(jitsiBaseURL: jitsiBaseURL)
                FormField(label: L10n.addFlowJitsiCustom.localized(),
                          placeholder: L10n.fieldJitsiURL.localized(),
                          text: jitsiBaseURL, keyboard: .URL, mono: true,
                          helper: L10n.addFlowJitsiInstanceNote.localized())
                FormField(label: L10n.addFlowJitsiRoomName.localized(),
                          placeholder: "olc-room", text: roomID, mono: true,
                          helper: L10n.addFlowJitsiRoomHint.localized())
            case "wbstream":
                FormField(label: L10n.fieldRoomID.localized(),
                          placeholder: L10n.roomIDPlaceholder.localized(),
                          text: roomID, mono: true,
                          helper: L10n.roomIDWbstreamHint.localized())
                roomSuggestion(carrier: c, into: roomID)
                FormField(label: L10n.wbTokenFieldLabel.localized(),
                          placeholder: L10n.wbTokenPlaceholder.localized(),
                          text: wbToken, secure: true, mono: true,
                          helper: L10n.wbTokenFooter.localized())
            default:
                FormField(label: L10n.fieldRoomID.localized(),
                          placeholder: L10n.roomIDPlaceholder.localized(),
                          text: roomID, mono: true,
                          helper: L10n.roomIDTelemostHint.localized() + " " + L10n.roomIDLinkHint.localized())
                roomSuggestion(carrier: c, into: roomID)
            }
        } header: {
            SignalSectionHeader(L10n.roomIDSectionHeader.localized())
        }
        .signalFormRows()
    }

    private func jitsiInstanceMenu(jitsiBaseURL: Binding<String>) -> some View {
        Menu {
            ForEach(CarrierEndpoints.jitsiInstances, id: \.self) { host in
                Button(host) {
                    jitsiBaseURL.wrappedValue = CarrierEndpoints.jitsiBaseURL(forInstance: host)
                }
            }
        } label: {
            HStack {
                Text(CarrierEndpoints.host(fromRoomID: jitsiBaseURL.wrappedValue) ?? jitsiBaseURL.wrappedValue)
                    .font(Theme.Typography.metricValue)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .padding(.horizontal, Theme.Metrics.s3)
            .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.fillBorder, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func roomSuggestion(carrier c: String, into binding: Binding<String>) -> some View {
        if binding.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty,
           let last = RoomMemory.lastRoom(forCarrier: c) {
            OlcButton(L10n.roomIDLastUsed_fmt.formatted(last), systemImage: "clock.arrow.circlepath",
                      role: .ghost, compact: true) { binding.wrappedValue = last }
        }
    }

    // MARK: SEI

    private var seiSection: some View {
        Section {
            Stepper("\(L10n.seiFpsLabel.localized()): \(seiFPS)", value: $seiFPS, in: SettingsStore.Defaults.seiFPSRange)
            Stepper("\(L10n.seiBatchLabel.localized()): \(seiBatch)", value: $seiBatch, in: SettingsStore.Defaults.seiBatchRange)
            Stepper("\(L10n.seiFragLabel.localized()): \(seiFrag)", value: $seiFrag, in: SettingsStore.Defaults.seiFragRange, step: 100)
            Stepper("\(L10n.seiAckLabel.localized()): \(seiACK)", value: $seiACK, in: SettingsStore.Defaults.seiACKRange, step: 100)
        } header: {
            SignalSectionHeader(L10n.seiSettingsHeader.localized())
        } footer: {
            Text(L10n.seiSettingsFooter.localized())
        }
        .font(Theme.Typography.body)
        .signalFormRows()
    }

    // MARK: Extras

    @ViewBuilder private var extrasSections: some View {
        Section {
            ForEach(extraCarriers, id: \.self) { c in
                Toggle(isOn: draftBinding(c).enabled) {
                    Text(L10n.installExtraToggle_fmt.formatted(CarrierTransportMatrix.carrierLabel(c)))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .frame(minHeight: Theme.Metrics.controlHeight)
            }
        } header: {
            SignalSectionHeader(L10n.installExtrasHeader.localized())
        } footer: {
            Text(L10n.installExtrasFooter.localized())
        }
        .signalFormRows()
        ForEach(enabledExtraCarriers, id: \.self) { c in
            let binding = draftBinding(c)
            transportSection(for: c, selection: binding.transport)
            roomSection(for: c, roomID: binding.roomID,
                        jitsiBaseURL: binding.jitsiBaseURL, wbToken: binding.wbToken)
        }
    }

    // MARK: Submit

    private func submit() {
        let primary = Self.options(carrier: carrier, transport: transport, roomID: roomID,
                                   jitsiBaseURL: jitsiBaseURL, wbToken: wbToken,
                                   sei: (seiFPS, seiBatch, seiFrag, seiACK))
        let extraOptions: [InstallOptions] = singleOnly ? [] : enabledExtraCarriers.map { c in
            let d = draft(c)
            return Self.options(carrier: c, transport: d.transport, roomID: d.roomID,
                                jitsiBaseURL: d.jitsiBaseURL, wbToken: d.wbToken, sei: nil)
        }
        onConfirm(primary, extraOptions)
        dismiss()
    }

    /// Pure mapping from the sheet's fields to `InstallOptions` (unit-tested).
    static func options(carrier: String, transport: String, roomID: String,
                        jitsiBaseURL: String, wbToken: String,
                        sei: (fps: Int, batch: Int, frag: Int, ack: Int)?) -> InstallOptions {
        let cleanedRoom = carrier == "telemost"
            ? TelemostRoomService.normalizedRoomInput(roomID)
            : roomID.components(separatedBy: .whitespacesAndNewlines).joined()
        let cleanedJitsi = jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var o = InstallOptions(carrier: carrier, transport: transport, roomID: cleanedRoom)
        o.jitsiBaseURL = cleanedJitsi.isEmpty ? AppConstants.defaultJitsiBaseURL : cleanedJitsi
        o.wbToken = carrier == "wbstream" ? wbToken.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if let sei {
            o.seiFPS = sei.fps; o.seiBatch = sei.batch; o.seiFrag = sei.frag; o.seiACK = sei.ack
        }
        return o
    }
}
