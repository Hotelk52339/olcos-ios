import SwiftUI

// boc #490
// #490 was: a 75-line nested List inside ServersView.containerScanSheet.
// Presentation only; the caller still owns scan results, adoption, dismissal
// and result cleanup. A failed scan never arrives here as an empty success.
struct ServerContainerScanView: View {
    let containers: [SSHRunner.FoundContainer]
    let onRestore: (SSHRunner.FoundContainer) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if containers.isEmpty {
                        Text(L10n.scanNoContainers.localized())
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } else {
                        ForEach(containers) { container in
                            containerRow(container)
                        }
                    }
                } header: {
                    SignalSectionHeader(L10n.actionScanVPS.localized(), systemImage: "magnifyingglass")
                }
                .signalFormRows()
            }
            .signalFormChrome()
            .navigationTitle(L10n.actionScanVPS.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.actionDone.localized(), action: onDone)
                }
            }
        }
    }

    private func containerRow(_ container: SSHRunner.FoundContainer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
            Text(container.name)
                .font(Theme.Typography.metricValue)
                .fixedSize(horizontal: false, vertical: true)
            containerDetails(container)
            Button(L10n.scanRestoreAction.localized()) { onRestore(container) }
                .font(Theme.Typography.label)
                .frame(minHeight: Theme.Metrics.controlHeight)
        }
        .padding(.vertical, Theme.Metrics.s2)
    }

    private func containerDetails(_ container: SSHRunner.FoundContainer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Label(container.status.shortLabel, systemImage: ServersView.scanGlyph(container.status))
            if !container.carrier.isEmpty {
                Text(CarrierTransportMatrix.carrierLabel(container.carrier)
                     + " · " + CarrierTransportMatrix.transportLabel(container.transport))
            }
            if !container.roomID.isEmpty {
                Text(L10n.roomPrefix_fmt.formatted(container.roomID))
            }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
// eoc #490
