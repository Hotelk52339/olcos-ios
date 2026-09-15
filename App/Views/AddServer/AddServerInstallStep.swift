import SwiftUI

/// Step 5 — review, live progress mirrored from `Provisioner.status`, and the
/// connections that landed in the store for the saved host.
struct AddServerInstallStep: View {
    @ObservedObject var flow: AddServerFlowController
    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            switch flow.installPhase {
            case .review:
                AddServerLead(text: .addFlowInstallLead)
                summaryCards
            case .running(let text):
                progressCard(text)
                summaryCards
            case .success(let text):
                resultCard(tone: .ok, title: L10n.addFlowInstallDone.localized(), subtitle: text)
                connectionsCard
            case .failure(let text):
                resultCard(tone: .error, title: L10n.addFlowInstallFailed.localized(), subtitle: text)
                Text(L10n.addFlowInstallFailedHint.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Summary

    @ViewBuilder private var summaryCards: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: 0) {
                OlcSectionHeader(L10n.addFlowSummaryServer.localized())
                AddServerFactRow(label: L10n.nameField.localized(), value: flow.access.trimmedLabel)
                Divider()
                AddServerFactRow(label: L10n.hostField.localized(),
                                 value: "\(flow.access.trimmedUser)@\(flow.access.trimmedHost):\(flow.access.port)",
                                 mono: true)
                if let facts = flow.check.facts, let os = facts.osName {
                    Divider()
                    AddServerFactRow(label: L10n.addFlowFactOS.localized(),
                                     value: [os, facts.arch].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
        OlcCard {
            VStack(alignment: .leading, spacing: 0) {
                OlcSectionHeader(L10n.addFlowSummaryProtocols.localized())
                ForEach(Array(flow.plan.selected.enumerated()), id: \.element) { index, carrier in
                    if index > 0 { Divider() }
                    protocolRow(carrier, isPrimary: index == 0)
                }
            }
        }
    }

    private func protocolRow(_ carrier: String, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            HStack(spacing: Theme.Metrics.s2) {
                Text(CarrierTransportMatrix.carrierLabel(carrier))
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                AddServerBadge(text: CarrierTransportMatrix.transportLabel(flow.plan.transport(for: carrier)),
                               tone: .unknown)
                if isPrimary, flow.plan.selected.count > 1 {
                    AddServerBadge(text: L10n.addFlowBadgePrimary.localized(), tone: .progress)
                }
                Spacer(minLength: 0)
            }
            if let room = roomSummary(carrier) {
                Text(room)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(minHeight: Theme.Metrics.rowMinHeight, alignment: .leading)
        .padding(.vertical, Theme.Metrics.s1)
    }

    private func roomSummary(_ carrier: String) -> String? {
        switch carrier {
        case "telemost":
            return flow.rooms.telemostRoomURI.isEmpty ? nil : flow.rooms.telemostRoomURI
        case "jitsi":
            let base = flow.rooms.jitsiBaseURL.trimmingCharacters(in: .whitespaces)
            let name = flow.rooms.jitsiRoomName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? base : base + "/" + name
        case "wbstream":
            return flow.rooms.wbRoomID.isEmpty ? nil : flow.rooms.wbRoomID
        default:
            return nil
        }
    }

    // MARK: Progress / result

    private func progressCard(_ text: String) -> some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                ServerSignalStatus(tone: .progress,
                                   title: L10n.addFlowInstallRunning.localized(),
                                   subtitle: text, isBusy: true)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Theme.Palette.accent)
            }
        }
    }

    private func resultCard(tone: OlcStatusTone, title: String, subtitle: String) -> some View {
        OlcCard {
            ServerSignalStatus(tone: tone, title: title, subtitle: subtitle)
        }
    }

    // MARK: Resulting connections

    private var resultingConnections: [ConnectionRecord] {
        guard let saved = flow.savedHost,
              let host = serverStore.hosts.first(where: { $0.id == saved.id }) else { return [] }
        let ids = [host.lastConnectionID].compactMap { $0 } + (host.extraConnectionIDs ?? [])
        return ids.compactMap { id in connections.connections.first { $0.id == id } }
    }

    private var connectionsCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                OlcSectionHeader(L10n.addFlowResultConnections.localized())
                let records = resultingConnections
                if records.isEmpty {
                    Text(L10n.addFlowResultPending.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(records) { record in
                        HStack(spacing: Theme.Metrics.s3) {
                            Image(systemName: "link")
                                .foregroundStyle(Theme.Palette.accent)
                                .accessibilityHidden(true)
                            Text(record.name)
                                .font(Theme.Typography.bodyStrong)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: Theme.Metrics.controlHeight)
                    }
                }
            }
        }
    }
}
