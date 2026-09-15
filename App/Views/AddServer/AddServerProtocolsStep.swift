import SwiftUI

/// Step 3 — carriers (multi-select, first pick is primary) and a transport per
/// carrier. Descriptions come from the verified `carrier*Desc` /
/// `transport*Desc` strings; the badges follow upstream's guidance only.
struct AddServerProtocolsStep: View {
    @ObservedObject var flow: AddServerFlowController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            AddServerLead(text: .addFlowProtocolsLead)
            ForEach(CarrierTransportMatrix.carriers, id: \.self) { carrier in
                carrierCard(carrier)
            }
            if flow.plan.isEmpty {
                AddServerInlineError(message: L10n.addFlowPickAtLeastOne.localized())
            }
            Text(L10n.carrierFooter.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Carrier card

    private func carrierCard(_ carrier: String) -> some View {
        let selected = flow.plan.selected.contains(carrier)
        let isPrimary = flow.plan.primary == carrier
        return OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { flow.plan.toggle(carrier) }
                } label: {
                    HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                            HStack(spacing: Theme.Metrics.s2) {
                                Text(CarrierTransportMatrix.carrierLabel(carrier))
                                    .font(Theme.Typography.title)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                badges(carrier, isPrimary: isPrimary, selected: selected)
                            }
                            Text(AddServerCarrierPlan.descriptionKey(forCarrier: carrier).localized())
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Theme.Metrics.s2)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(Theme.Typography.title)
                            .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])

                if selected {
                    transportPicker(carrier)
                    if !isPrimary {
                        OlcButton(L10n.addFlowBadgePrimary.localized(), systemImage: "star",
                                  role: .ghost, compact: true) {
                            withAnimation(.snappy) { flow.plan.makePrimary(carrier) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func badges(_ carrier: String, isPrimary: Bool, selected: Bool) -> some View {
        if let badge = AddServerCarrierPlan.badge(for: carrier).title {
            AddServerBadge(text: badge.localized(),
                           tone: AddServerCarrierPlan.badge(for: carrier) == .recommended ? .ok : .unknown)
        }
        if carrier == "telemost" {
            AddServerBadge(text: L10n.addFlowNeedsYandex.localized(), tone: .warn)
        }
        if isPrimary, flow.plan.selected.count > 1 {
            AddServerBadge(text: L10n.addFlowBadgePrimary.localized(), tone: .progress)
        }
    }

    // MARK: Transport

    private func transportPicker(_ carrier: String) -> some View {
        let options = AddServerCarrierPlan.transportOptions(for: carrier)
        let recommended = AddServerCarrierPlan.recommendedTransport(for: carrier)
        let binding = Binding<String>(
            get: { flow.plan.transport(for: carrier) },
            set: { flow.plan.transport[carrier] = $0 }
        )
        return VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            OlcSectionHeader(L10n.addFlowTransportFor_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier)))
            ForEach(options, id: \.self) { transport in
                transportRow(transport, carrier: carrier, selected: binding.wrappedValue == transport,
                             recommended: transport == recommended) {
                    Haptics.tap()
                    binding.wrappedValue = transport
                }
            }
        }
    }

    private func transportRow(_ transport: String, carrier: String, selected: Bool,
                              recommended: Bool, action: @escaping () -> Void) -> some View {
        let compat = CarrierTransportMatrix.compat(carrier: carrier, transport: transport)
        return Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    HStack(spacing: Theme.Metrics.s2) {
                        Text(CarrierTransportMatrix.transportLabel(transport))
                            .font(selected ? Theme.Typography.bodyStrong : Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if recommended {
                            AddServerBadge(text: L10n.addFlowBadgeRecommended.localized(), tone: .ok)
                        }
                    }
                    Text(AddServerCarrierPlan.descriptionKey(forTransport: transport).localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if compat == .question {
                        Text(L10n.matrixQuestion_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier)))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.orange)
                    }
                }
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
