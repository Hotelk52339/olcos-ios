import SwiftUI

// MARK: - AddConnectionView
//
// Editor sheet for ConnectionRecord.
//
//  CREATE mode (existing == nil)
//    – Import first: Paste URI / Scan QR, plus a field for a typed or edited
//      `olcrtc://` link. A parsed link fills the parameters below; a
//      subscription link or list is handed to `onImport`.
//    – The parameters stay visible so the user can check what was parsed or
//      build a record by hand.
//
//  EDIT mode (existing != nil)
//    – No import section: editing means tweaking existing parameters.
//
// Groups: a record's `groupName` comes from its subscription (`#name`) and is
// preserved on edit; manual records go to the default group. There is no group
// field — a hand-typed section label had no other use on the main screen.
//
// Today the form renders an olcrtc-shaped configuration (carrier + transport
// pickers, room/key/clientID fields). Other protocols would branch on a
// user-chosen protocol type and swap in their own editor.

struct AddConnectionView: View {
    var existing: ConnectionRecord? = nil
    /// Invoked when a pasted blob resolves to a subscription (an https URL to
    /// fetch, or raw sub.md text) rather than a single connection. The host
    /// routes it through the confirm-then-import + dedup flow. A single olcrtc://
    /// link is handled in-place (fills the fields below), so it never calls this.
    var onImport: ((OlcrtcSubscription.ImportInput) -> Void)? = nil
    var onSave: (ConnectionRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var uriText      = ""
    @State private var parseError   = ""
    @State private var showQRScan   = false

    @State private var name      = ""
    @State private var carrier   = "wbstream"
    // #284: default to the carrier's recommended transport (wbstream+datachannel
    // is now `.question`); keeps the initial pick consistent with the matrix and
    // with InstallOptions / ReconfigureOptions.
    @State private var transport = CarrierTransportMatrix.defaultTransport(for: "wbstream")
    @State private var roomID    = ""
    @State private var key       = ""
    @State private var clientID  = "default"
    @State private var socksUser = ""
    @State private var socksPass = ""
    @State private var vp8FPS      : Int? = nil
    @State private var vp8BatchSize: Int? = nil
    // #355: sei params carried through paste/parse so a seichannel URI round-trips
    // its tuning (no sei UI yet — these hold the parsed/edited values silently).
    @State private var seiFPS  : Int = 30
    @State private var seiBatch: Int = 10
    @State private var seiFrag : Int = 1200
    @State private var seiACK  : Int = 1

    private var isCreate: Bool { existing == nil }

    private var isVP8: Bool { transport == "vp8channel" }

    // #365: sei params get a dedicated editor only for the seichannel transport.
    private var isSEI: Bool { transport == "seichannel" }

    // (audit) deliberately NOT gated on the compat matrix: an existing record or
    // an imported olcrtc:// URI may hold a combo the local matrix marks ✗ (a
    // remote server can be ahead of our table) — those stay savable, with the
    // red chip outline + footer as the warning. Only NEW picks are prevented,
    // via the disabled chips below.
    private var isValid: Bool {
        !name.isEmpty && !carrier.isEmpty && !transport.isEmpty
            && !roomID.isEmpty && !key.isEmpty && !clientID.isEmpty
            && validationError == nil   // #470
    }

    // boc #470
    /// The structural rules the engine applies at connect time
    /// (`TunnelManager.validate`, run by `OlcrtcEngine.validate`): a 64-hex key,
    /// a client ID without whitespace. #470 was: Save required only non-empty
    /// fields, so a key with one character clipped was stored, sat in the list
    /// looking valid, and failed at Connect with "key length 63". Silent while
    /// the three fields are still blank — the emptiness rule above already
    /// disables Save.
    private var validationError: String? {
        guard !roomID.isEmpty, !key.isEmpty, !clientID.isEmpty else { return nil }
        return TunnelManager.validate(params: OlcrtcConnection(
            carrier: carrier, transport: transport, roomID: roomID, key: key, clientID: clientID))
    }
    // eoc #470

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

    /// (audit) compat footer under the transport picker — this editor had none
    /// (ported from InstallOptionsView.transportFooter, minus the server-side
    /// tuning note, which doesn't apply to a client-side record).
    private var transportFooter: String {
        let label = CarrierTransportMatrix.carrierLabel(carrier)
        switch CarrierTransportMatrix.compat(carrier: carrier, transport: transport) {
        case .recommended: return L10n.matrixRecommended_fmt.formatted(label)
        case .ok:          return L10n.matrixWorks_fmt.formatted(label)
        case .question:    return L10n.matrixQuestion_fmt.formatted(label)
        case .fail:        return L10n.matrixFail_fmt.formatted(label)
        case .unknown:     return L10n.matrixUnknown_fmt.formatted(label)
        }
    }

    /// Round 2: the verdict is drawn as a tinted `FormNote`, not a lone "★ …"
    /// caption. Tone follows the matrix cell; "works" / "no data" stay neutral.
    private var transportTone: OlcStatusTone? {
        switch CarrierTransportMatrix.compat(carrier: carrier, transport: transport) {
        case .recommended: return .ok
        case .question:    return .warn
        case .fail:        return .error
        case .ok, .unknown: return nil
        }
    }

    /// Room helper: only Telemost accepts a pasted invite link (collapsed to
    /// the bare id by `TelemostRoomService.normalizedRoomInput` in `onChange`).
    private var roomHelper: String? {
        carrier == "telemost" ? L10n.roomIDLinkHint.localized() : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCreate {
                    uriSection
                }
                parametersSection
                roomSection
                accessSection
                if isVP8 {
                    vp8Section
                }
                if isSEI {
                    seiSection
                }
                // SOCKS auth (socksUser/socksPass) is configured globally in
                // Settings, not per-connection.
            }
            // Round 2: the same grouped-card chrome as Settings / Reconfigure —
            // sentence-case section headers, card rows, one pinned primary action.
            .signalFormChrome()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isCreate
                             ? L10n.newConnectionTitle.localized()
                             : L10n.editConnectionTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: shared sheet chrome (✕ close + full-width primary footer).
            .olcSheet(confirm: L10n.save.localized(), disabled: !isValid) { save() }
        }
        .onAppear { prefill() }
        .sheet(isPresented: $showQRScan) {
            QRScannerSheet { scanned in
                uriText = scanned
                parseURI()
            }
        }
    }

    // MARK: Import

    /// Paste / Scan first, then a field for a typed or edited link. Every path
    /// feeds `applyParsed`, which fills the parameters below.
    private var uriSection: some View {
        Section {
            HStack(spacing: Theme.Metrics.s2) {
                OlcButton(L10n.pasteURIAction.localized(), systemImage: "doc.on.clipboard",
                          role: .secondary, fillWidth: true) {
                    pasteAndImport(UIPasteboard.general.string ?? "")
                }
                OlcButton(L10n.scanQRAction.localized(), systemImage: "qrcode.viewfinder",
                          role: .secondary, fillWidth: true) {
                    showQRScan = true
                }
            }
            .padding(.vertical, Theme.Metrics.s1)
            .listRowSeparator(.hidden)

            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                // The URI scheme is a wire-format literal, not copy.
                TextField("olcrtc://…", text: $uriText, axis: .vertical)
                    .font(Theme.Typography.metricValue)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1...3)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding(.horizontal, Theme.Metrics.s3)
                    .padding(.vertical, Theme.Metrics.s2)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.controlHeight)
                    .background(Theme.Palette.fill, in: fieldShape)
                    .overlay { fieldShape.strokeBorder(Theme.Palette.fillBorder, lineWidth: 1) }
                    .onChange(of: uriText) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, let cfg = try? OlcrtcURI.parse(trimmed) else { return }
                        applyParsed(cfg)
                        parseError = ""
                    }
                if !parseError.isEmpty {
                    Text(parseError)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            SignalSectionHeader(L10n.importByURI.localized(), systemImage: "link")
        } footer: {
            Text(L10n.importHint.localized())
        }
        .signalFormRows()
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous)
    }

    // MARK: Parameters — name, service, transport

    private var parametersSection: some View {
        Section {
            FormField(label: L10n.nameSettingLabel.localized(),
                      placeholder: L10n.namePlaceholder.localized(), text: $name)

            // Only a USER carrier pick runs through this Binding's setter.
            // applyParsed / prefill write the @State directly (carrier +
            // transport together), so an imported link or an edited record
            // keeps its exact combo. When the user's new carrier makes the
            // current transport a ✗ combo, transport snaps to the carrier's default.
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                Text(L10n.sectionCarrier.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                OlcChipPicker(selection: Binding(
                    get: { carrier },
                    set: { newCarrier in
                        carrier = newCarrier
                        if CarrierTransportMatrix.compat(carrier: newCarrier,
                                                         transport: transport) == .fail {
                            transport = CarrierTransportMatrix.defaultTransport(for: newCarrier)
                        }
                    }
                ), options: CarrierTransportMatrix.carriers.map { ($0, CarrierTransportMatrix.carrierLabel($0)) })
            }
            .padding(.vertical, Theme.Metrics.s1)

            // ✗ combos are disabled for NEW picks; an existing / imported record
            // already holding one stays selected + savable (red chip outline +
            // the red note below carry the warning).
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                Text(L10n.labelTransport.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                OlcChipPicker(selection: $transport, options: transportOptions)
                FormNote(text: transportFooter, tone: transportTone)
            }
            .padding(.vertical, Theme.Metrics.s1)
        } header: {
            SignalSectionHeader(L10n.parametersHeader.localized())
        }
        .signalFormRows()
    }

    // MARK: Room

    private var roomSection: some View {
        Section {
            FormField(label: L10n.fieldRoomID.localized(),
                      placeholder: L10n.roomIDPlaceholder.localized(),
                      text: $roomID, mono: true, helper: roomHelper)
                .onChange(of: roomID) { _, new in
                    // A pasted Telemost invite link collapses to the bare id
                    // the server was installed with; other carriers only lose
                    // whitespace. The room STRING must match the server's
                    // byte for byte (see TelemostRoomService.normalizedRoomInput).
                    let stripped = carrier == "telemost"
                        ? TelemostRoomService.normalizedRoomInput(new)
                        : new.filter { !$0.isWhitespace }
                    if stripped != new { roomID = stripped }
                }
            roomSuggestion()
        } header: {
            SignalSectionHeader(L10n.roomIDSectionHeader.localized())
        }
        .signalFormRows()
    }

    // MARK: Access — client id + key

    private var accessSection: some View {
        Section {
            FormField(label: L10n.clientIDLabel.localized(), placeholder: "default",
                      text: $clientID, helper: L10n.clientIDFooter.localized())
            FormField(label: L10n.keyHexLabel.localized(),
                      placeholder: L10n.keyPlaceholder.localized(),
                      text: $key, secure: true, mono: true)
                .onChange(of: key) { _, new in
                    // A key copied from a terminal or chat arrives with a
                    // trailing newline or grouping spaces; the engine wants 64
                    // bare hex digits. Case is left alone (hex is case-free).
                    let stripped = new.filter { !$0.isWhitespace }
                    if stripped != new { key = stripped }
                }
            // The sentence Connect would have shown, shown here instead.
            if let why = validationError {
                FormNote(text: why, tone: .error)
                    .listRowSeparator(.hidden)
            }
        } header: {
            SignalSectionHeader(L10n.formAccessSectionHeader.localized())
        }
        .signalFormRows()
    }

    /// #456: one tappable row offering the last room used with THIS carrier, so a
    /// new connection to a room the user already joined isn't typed out again.
    /// Shown only while CREATING and only while the field is still empty — it never
    /// competes with a pasted URI's value or an existing record's. Its own
    /// `@ViewBuilder` (this Form's section is already long).
    @ViewBuilder
    private func roomSuggestion() -> some View {
        if isCreate, roomID.isEmpty,
           let last = RoomMemory.lastRoom(forCarrier: carrier), !last.isEmpty {
            Button {
                roomID = last
            } label: {
                Text(L10n.roomIDLastUsed_fmt.formatted(last))
                    .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption)
                    .foregroundStyle(Theme.Signal.stroke)   // round 2: same action tint as Reconfigure
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: VP8 per-connection override

    private var vp8Section: some View {
        Section {
            HStack {
                Text(L10n.vp8FpsLabel.localized())
                Spacer()
                Text(vp8FPS.map(String.init)
                     ?? L10n.globalDefault_fmt.formatted(SettingsStore.shared.vp8FPS))
                    .foregroundStyle(vp8FPS == nil ? .secondary : .primary)
                Stepper("", value: Binding(
                    get: { vp8FPS ?? SettingsStore.shared.vp8FPS },
                    set: { vp8FPS = $0 }
                ), in: SettingsStore.Defaults.vp8FPSRange)   // #470 was: 1...120 — the global setting clamps to the room limit (60)
                .labelsHidden()
                if vp8FPS != nil {
                    Button { vp8FPS = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(L10n.vp8BatchLabel.localized())
                Spacer()
                Text(vp8BatchSize.map(String.init)
                     ?? L10n.globalDefault_fmt.formatted(SettingsStore.shared.vp8BatchSize))
                    .foregroundStyle(vp8BatchSize == nil ? .secondary : .primary)
                Stepper("", value: Binding(
                    get: { vp8BatchSize ?? SettingsStore.shared.vp8BatchSize },
                    set: { vp8BatchSize = $0 }
                ), in: SettingsStore.Defaults.vp8BatchRange)   // #470 was: 1...64 — the global setting allows 256
                .labelsHidden()
                if vp8BatchSize != nil {
                    Button { vp8BatchSize = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            SignalSectionHeader(L10n.vp8ParamsHeader.localized())
        } footer: {
            // #471: B9 — a Form footer is already a caption. was: .font(.caption2)
            Text(L10n.overrideHint.localized())
        }
        .signalFormRows()
    }

    // MARK: SEI per-connection params (#365)

    // Mirrors `vp8Section` but sei values are non-optional on OlcrtcConnection
    // (defaults 30/10/1200/1, never "global"), so each row is a plain
    // value + Stepper bound straight to the Int state — no nil/×-reset affordance.
    private var seiSection: some View {
        Section {
            seiRow(L10n.seiFpsLabel.localized(),   value: $seiFPS,   range: 1...120)
            // #470: the bounds the install sheet (InstallOptionsView) and upstream's
            // validator accept — a URI carrying sei batch=200 (installable) could
            // not be re-edited here without the stepper clamping it to 64.
            // #470 was: range: 1...64 / range: 1...8192, step: 100
            seiRow(L10n.seiBatchLabel.localized(), value: $seiBatch, range: 1...256)
            seiRow(L10n.seiFragLabel.localized(),  value: $seiFrag,  range: 100...60000, step: 100)
            seiRow(L10n.seiAckLabel.localized(),   value: $seiACK,   range: 0...10000, step: 1)
        } header: {
            SignalSectionHeader(L10n.seiParamsHeader.localized())
        } footer: {
            // #471: B9 — a Form footer is already a caption. was: .font(.caption2)
            Text(L10n.seiParamsHint.localized())
        }
        .signalFormRows()
    }

    private func seiRow(_ label: String, value: Binding<Int>,
                        range: ClosedRange<Int>, step: Int = 1) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(value.wrappedValue))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    // (audit) was: socksAuthSection — dead since SOCKS auth moved to Settings
    // (never referenced by any body). The $socksUser/$socksPass STATE stays:
    // prefill()/save() round-trip the values stored on existing records.

    // MARK: Logic

    /// #414: the single Parsed→editor-fields mapping, via `OlcrtcConnection.init(from:)`
    /// (which holds the sei/vp8 defaults). Shared by both URI-entry paths — the live
    /// field auto-parse and `parseURI` — so the mapping isn't duplicated (#355's
    /// `applySEI` is folded into `init(from:)`'s `?? default`).
    private func applyParsed(_ cfg: OlcrtcURI.Parsed) {
        let params = OlcrtcConnection(from: cfg)
        carrier      = params.carrier
        transport    = params.transport
        roomID       = params.roomID
        key          = params.key
        clientID     = params.clientID
        vp8FPS       = params.vp8FPS
        vp8BatchSize = params.vp8BatchSize
        seiFPS       = params.seiFPS
        seiBatch     = params.seiBatch
        seiFrag      = params.seiFrag
        seiACK       = params.seiACK
        if name.isEmpty {
            name = cfg.mimo.isEmpty ? "\(cfg.carrier) · \(cfg.transport)" : cfg.mimo
        }
    }

    /// #361: paste-and-import. Detects what the pasted blob is and routes it:
    ///   • a single olcrtc:// link → fill the fields here (the #354 single import);
    ///   • an https:// / olcrtc-sub:// URL, or raw sub.md text → hand to `onImport`,
    ///     which runs the confirm-then-import + dedup flow.
    /// A QR scan reuses `parseURI` directly (a QR encodes one connection URI).
    private func pasteAndImport(_ text: String) {
        let detected = OlcrtcSubscription.detectImport(text)
        switch detected {
        case .connectionURI(let uri):
            uriText = uri
            parseURI()
        case .subscriptionURL, .subscriptionBody:
            if let onImport {
                onImport(detected)
            } else {
                // No import host wired (e.g. edit mode) — fall back to field fill.
                uriText = text
                parseURI()
            }
        case .unrecognized:
            uriText = text
            parseURI()   // surfaces the parse error for an empty/garbage paste
        }
    }

    private func parseURI() {
        parseError = ""
        do {
            let cfg = try OlcrtcURI.parse(uriText)
            applyParsed(cfg)   // #414: shared Parsed→fields mapping (via init(from:))
            LogStore.shared.log(.connection,
                "✓ URI parsed: carrier=\(cfg.carrier) transport=\(cfg.transport) room=\(cfg.roomID.prefix(8))…")
        } catch {
            parseError = error.localizedDescription
            LogStore.shared.log(.connection, "✗ URI parse failed: \(error.localizedDescription)")
        }
    }

    private func save() {
        var params = OlcrtcConnection(
            carrier:      carrier,
            transport:    transport,
            roomID:       roomID,
            key:          key,
            clientID:     clientID,
            vp8FPS:       vp8FPS,
            vp8BatchSize: vp8BatchSize,
            socksUser:    socksUser,
            socksPass:    socksPass,
            seiFPS:       seiFPS,    // #355
            seiBatch:     seiBatch,
            seiFrag:      seiFrag,
            seiACK:       seiACK
        )
        // boc #469: the editor has no field for these, so rebuilding the record
        // from its @State alone dropped them on every Save. The WB token went to
        // "" until relaunch (the Keychain still held it — `save()` never deletes
        // a blanked secret — so the record silently dialled as a guest until the
        // next hydration); the #465 room clock reset to "unknown"; and the
        // subscription provenance vanished, so the next refresh re-imported the
        // same node as a duplicate row. Carry through everything this sheet
        // cannot edit; the stamp only survives when the room is the same room.
        if let existing, case .olcrtc(let prior) = existing.details {
            params.wbToken       = prior.carrier == carrier ? prior.wbToken : ""
            params.roomCreatedAt = prior.roomID == roomID ? prior.roomCreatedAt : nil
        }
        // eoc #469
        // The group is subscription-derived (`#name`) or the default; editing
        // never moves a record between groups.
        var record = ConnectionRecord(
            id:        existing?.id ?? UUID(),
            name:      name,
            groupName: existing?.groupName ?? ConnectionRecord.defaultGroupName,
            details:   .olcrtc(params)
        )
        // #469: keep the subscription provenance (see above) — `diffSubscription`
        // matches prior records by source + node key, and a record that lost
        // them is invisible to the diff, i.e. re-added beside itself.
        if let existing {
            record.subSourceURL = existing.subSourceURL
            record.subNodeKey   = existing.subNodeKey
            record.subIP        = existing.subIP
            record.subComment   = existing.subComment
            record.subUsed      = existing.subUsed
            record.subAvailable = existing.subAvailable
        }
        // #456: seed the per-carrier room suggestion that the install / reconfigure
        // sheets (and `roomSuggestion()` above) read, so the app stops asking for a
        // value it has already been told once.
        RoomMemory.remember(carrier: carrier, room: roomID)
        onSave(record)
        Haptics.success()   // #455: a saved/edited connection lands with a success tap
        dismiss()
    }

    private func prefill() {
        guard let r = existing else {
            // Create mode: reset all fields to defaults
            name = ""
            carrier = "wbstream"; transport = CarrierTransportMatrix.defaultTransport(for: "wbstream")
            roomID = ""; key = ""; clientID = "default"
            socksUser = ""; socksPass = ""; vp8FPS = nil; vp8BatchSize = nil
            seiFPS = 30; seiBatch = 10; seiFrag = 1200; seiACK = 1   // #355
            uriText = ""; parseError = ""
            return
        }
        name      = r.name
        if case .olcrtc(let p) = r.details {
            carrier      = p.carrier
            transport    = p.transport
            roomID       = p.roomID
            key          = p.key
            clientID     = p.clientID
            vp8FPS       = p.vp8FPS
            vp8BatchSize = p.vp8BatchSize
            socksUser    = p.socksUser
            socksPass    = p.socksPass
            seiFPS       = p.seiFPS    // #355
            seiBatch     = p.seiBatch
            seiFrag      = p.seiFrag
            seiACK       = p.seiACK
        }
    }
}
