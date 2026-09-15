import SwiftUI

/// Step 2 — one SSH round-trip: host key first contact, OS / arch, container
/// runtime, existing olcOS containers.
struct AddServerCheckStep: View {
    @ObservedObject var flow: AddServerFlowController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            AddServerLead(text: .addFlowCheckLead)
            trustCard
            statusCard
            if let facts = flow.check.facts { factsCard(facts) }
        }
        .onAppear { if flow.check == .idle { flow.startCheck() } }
    }

    // MARK: Host key (TOFU) — status only, never a fingerprint

    private var trustCard: some View {
        OlcCard {
            switch flow.trust {
            case .firstContact:
                ServerSignalStatus(tone: .unknown,
                                   title: L10n.addFlowTofuFirstTitle.localized(),
                                   subtitle: L10n.addFlowTofuFirstBody.localized())
            case .known:
                ServerSignalStatus(tone: .ok,
                                   title: L10n.addFlowTofuKnownTitle.localized(),
                                   subtitle: L10n.addFlowTofuKnownBody.localized())
            case .mismatch:
                ServerSignalStatus(tone: .error,
                                   title: L10n.addFlowTofuMismatchTitle.localized(),
                                   subtitle: L10n.sshHostKeyMismatch.localized())
            }
        }
    }

    // MARK: Connection

    private var statusCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                switch flow.check {
                case .idle, .running:
                    ServerSignalStatus(tone: .progress,
                                       title: L10n.addFlowCheckRunning.localized(),
                                       subtitle: "\(flow.access.trimmedUser)@\(flow.access.trimmedHost):\(flow.access.port)",
                                       isBusy: true)
                case .done:
                    ServerSignalStatus(tone: .ok,
                                       title: L10n.addFlowCheckOK.localized(),
                                       subtitle: "\(flow.access.trimmedUser)@\(flow.access.trimmedHost):\(flow.access.port)")
                case .failed(let message):
                    ServerSignalStatus(tone: .error,
                                       title: L10n.addFlowCheckFailed.localized(),
                                       subtitle: message)
                    OlcButton(L10n.actionRetry.localized(), systemImage: "arrow.clockwise",
                              role: .secondary, fillWidth: true) { flow.startCheck() }
                }
            }
        }
    }

    // MARK: Facts

    private func factsCard(_ facts: AddServerHostFacts) -> some View {
        OlcCard {
            VStack(alignment: .leading, spacing: 0) {
                AddServerFactRow(label: L10n.addFlowFactOS.localized(),
                                 value: facts.osName ?? L10n.addFlowFactUnknown.localized())
                Divider()
                AddServerFactRow(label: L10n.addFlowFactArch.localized(),
                                 value: facts.arch ?? L10n.addFlowFactUnknown.localized(), mono: true)
                Divider()
                AddServerFactRow(label: L10n.addFlowFactRuntime.localized(),
                                 value: facts.runtime?.rawValue ?? L10n.addFlowFactRuntimeNone.localized(),
                                 mono: facts.runtime != nil)
                Divider()
                ServerSignalStatus(tone: facts.existing.isEmpty ? .ok : .warn,
                                   title: facts.existing.isEmpty
                                       ? L10n.addFlowFactExistingNone.localized()
                                       : L10n.addFlowFactExisting_fmt.formatted(facts.existing.joined(separator: ", ")),
                                   subtitle: facts.existing.isEmpty ? "" : L10n.installExistingFoundBody.localized())
                    .padding(.top, Theme.Metrics.s3)
            }
        }
    }
}
