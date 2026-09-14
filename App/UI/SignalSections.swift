import SwiftUI

// boc #492: shared presentation only. These components do not own stores,
// perform network work, or replace the native controls' existing bindings.
struct SignalSectionHeader: View {
    let title: String
    let systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: Theme.Metrics.s2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Typography.bodyStrong)
        .textCase(nil)
        .padding(.top, Theme.Metrics.s2)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SignalSettingsLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Native Forms remain Forms: scrolling, text fields, security, and focus
    /// stay with their existing owners instead of a presentation-only rewrite.
    func signalFormChrome() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.bg)
            .tint(Theme.Signal.stroke)
            .listSectionSpacing(Theme.Metrics.s4)
            .environment(\.defaultMinListRowHeight, Theme.Metrics.rowMinHeight)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
    }

    /// Section-level application styles each native row without imposing a
    /// fixed height that would clip French or accessibility-sized text.
    func signalFormRows() -> some View {
        self
            .listRowBackground(Theme.Palette.card)
            .listRowSeparatorTint(Theme.Palette.cardBorder)
    }
}
// eoc #492
