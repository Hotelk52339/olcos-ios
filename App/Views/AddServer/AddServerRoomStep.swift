import SwiftUI

/// Step 4 — one card per selected carrier.
/// Telemost: sign in to Yandex if needed, then the room is created here and
/// its ID travels into `InstallOptions.roomID`. Jitsi: instance + room name.
/// WB Stream: room ID + optional account token.
struct AddServerRoomStep: View {
    @ObservedObject var flow: AddServerFlowController
    @ObservedObject var yandexStore: YandexSessionStore
    @State private var showYandexLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            AddServerLead(text: .addFlowRoomLead)
            ForEach(flow.plan.selected, id: \.self) { carrier in
                switch carrier {
                case "telemost": telemostCard
                case "jitsi":    jitsiCard
                case "wbstream": wbstreamCard
                default:         EmptyView()
                }
            }
        }
        .sheet(isPresented: $showYandexLogin) {
            YandexLoginView { session in
                showYandexLogin = false
                flow.yandexSignedIn(session)
            }
        }
    }

    private func roomError(_ carrier: String) -> String? {
        guard flow.showRoomErrors,
              flow.roomErrors.contains(.missing(carrier: carrier)) else { return nil }
        return L10n.addFlowRoomMissing_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier))
    }

    private func header(_ carrier: String) -> some View {
        HStack(spacing: Theme.Metrics.s2) {
            Text(CarrierTransportMatrix.carrierLabel(carrier))
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)
            AddServerBadge(text: CarrierTransportMatrix.transportLabel(flow.plan.transport(for: carrier)),
                           tone: .unknown)
            Spacer(minLength: 0)
        }
    }

    // MARK: Telemost — auto room

    private var telemostCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                header("telemost")
                switch flow.telemost {
                case .needsSignIn:
                    ServerSignalStatus(tone: .warn,
                                       title: L10n.telemostRoomSignInAction.localized(),
                                       subtitle: L10n.addFlowYandexSignInBody.localized())
                    OlcButton(L10n.telemostRoomSignInAction.localized(), systemImage: "person.crop.circle.badge.checkmark",
                              role: .primary, fillWidth: true) { showYandexLogin = true }
                case .creating:
                    ServerSignalStatus(tone: .progress,
                                       title: L10n.addFlowTelemostCreating.localized(),
                                       subtitle: L10n.telemostRoomKeychainNote.localized(),
                                       isBusy: true)
                case .created(let room):
                    ServerSignalStatus(tone: .ok,
                                       title: L10n.addFlowTelemostCreated.localized(),
                                       subtitle: L10n.addFlowTelemostCreatedBody.localized())
                    AddServerFactRow(label: L10n.roomIDLabel.localized(), value: room.id, mono: true)
                    HStack(spacing: Theme.Metrics.s3) {
                        OlcButton(L10n.telemostNewRoomAction.localized(), systemImage: "arrow.clockwise",
                                  role: .secondary, compact: true) { flow.createTelemostRoom() }
                        OlcButton(L10n.telemostRoomOtherAccountAction.localized(), systemImage: "person.2",
                                  role: .ghost, compact: true) { flow.switchYandexAccount() }
                    }
                case .failed(let message, let needsSignIn):
                    ServerSignalStatus(tone: .error,
                                       title: L10n.addFlowTelemostFailed.localized(),
                                       subtitle: message)
                    if needsSignIn {
                        OlcButton(L10n.telemostRoomSignInAction.localized(), systemImage: "person.crop.circle.badge.checkmark",
                                  role: .primary, fillWidth: true) { showYandexLogin = true }
                    } else {
                        OlcButton(L10n.telemostRoomRetryAction.localized(), systemImage: "arrow.clockwise",
                                  role: .secondary, fillWidth: true) { flow.createTelemostRoom() }
                    }
                }
                if let e = roomError("telemost"), flow.telemost != .creating {
                    AddServerInlineError(message: e)
                }
            }
        }
    }

    // MARK: Jitsi — instance + room name

    private var jitsiCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                header("jitsi")
                OlcSectionHeader(L10n.addFlowJitsiInstance.localized())
                Menu {
                    ForEach(CarrierEndpoints.jitsiInstances, id: \.self) { host in
                        Button(host) {
                            flow.rooms.jitsiBaseURL = CarrierEndpoints.jitsiBaseURL(forInstance: host)
                        }
                    }
                } label: {
                    HStack {
                        Text(CarrierEndpoints.host(fromRoomID: flow.rooms.jitsiBaseURL) ?? flow.rooms.jitsiBaseURL)
                            .font(Theme.Typography.metricValue)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Metrics.s2)
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .frame(minHeight: Theme.Metrics.controlHeight)
                    .padding(.horizontal, Theme.Metrics.s3)
                    .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
                }
                AddServerTextField(label: L10n.addFlowJitsiCustom.localized(),
                                   placeholder: L10n.fieldJitsiURL.localized(),
                                   text: $flow.rooms.jitsiBaseURL, mono: true)
                    .keyboardType(.URL)
                Text(L10n.addFlowJitsiInstanceNote.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                AddServerTextField(label: L10n.addFlowJitsiRoomName.localized(),
                                   placeholder: "olc-room",
                                   text: $flow.rooms.jitsiRoomName, mono: true)
                Text(L10n.addFlowJitsiRoomHint.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if let e = roomError("jitsi") { AddServerInlineError(message: e) }
            }
        }
    }

    // MARK: WB Stream — room id + token

    private var wbstreamCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                header("wbstream")
                AddServerTextField(label: L10n.fieldRoomID.localized(),
                                   placeholder: "1234567890",
                                   text: $flow.rooms.wbRoomID, mono: true)
                Text(L10n.roomIDWbstreamHint.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = RoomMemory.lastRoom(forCarrier: "wbstream"), flow.rooms.wbRoomID.isEmpty {
                    OlcButton(L10n.roomIDLastUsed_fmt.formatted(last), systemImage: "clock.arrow.circlepath",
                              role: .ghost, compact: true) { flow.rooms.wbRoomID = last }
                }
                FormField(label: L10n.wbTokenFieldLabel.localized(),
                          placeholder: L10n.wbTokenPlaceholder.localized(),
                          text: $flow.rooms.wbToken, secure: true, mono: true,
                          helper: L10n.wbTokenFooter.localized())
                if let e = roomError("wbstream") { AddServerInlineError(message: e) }
            }
        }
    }
}

/// Plain labelled text field in the wizard's field style.
struct AddServerTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField(placeholder, text: $text)
                .font(mono ? Theme.Typography.metricValue : Theme.Typography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: Theme.Metrics.chipHeight)
                .padding(.horizontal, Theme.Metrics.s3)
                .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
                    .stroke(Theme.Palette.fillBorder, lineWidth: 1))
        }
    }
}
