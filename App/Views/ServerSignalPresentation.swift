import SwiftUI

// boc #490
// #490: server-only presentation. No store ownership, network work or clocks;
// evidence and actions are supplied by the existing ServersView resolvers.
enum ServerPresentationPolicy {
    /// A navigation route is an identity, not a permanent metadata snapshot.
    static func currentHost(snapshot: ServerHost, hosts: [ServerHost]) -> ServerHost {
        hosts.first { $0.id == snapshot.id } ?? snapshot
    }

    /// Short state changes only; Reduce Motion removes even this transition.
    static func transitionDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : 0.18
    }

    /// An unavailable option remains visible if imported, never selectable.
    static func allowsSelectionChange<Value: Equatable>(
        current: Value, proposed: Value, isDisabled: Bool
    ) -> Bool {
        !isDisabled && current != proposed
    }
}

/// Listing state is separate from tunnel health: unread is not an empty
/// successful scan, and a real in-flight read is the only loading indicator.
enum ServerProtocolListing: Equatable {
    case absent, unread, loading, loaded

    static func resolve(hasContainer: Bool, isLoading: Bool, hasRead: Bool) -> Self {
        if isLoading { return .loading }
        if hasRead { return .loaded }
        return hasContainer ? .unread : .absent
    }
}

/// A quiet, non-pulsing status treatment. Never infers health from a process,
/// a stored credential, an accent or an animation. The complete dated sentence
/// wraps rather than dropping the reason at large Dynamic Type sizes.
struct ServerSignalStatus: View {
    let tone: OlcStatusTone
    let title: String
    let subtitle: String
    var isBusy = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s3) {
            glyph
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(title)
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var glyph: some View {
        if isBusy {
            ProgressView().controlSize(.small)
                .accessibilityHidden(true)
        } else {
            Image(systemName: tone.symbol)
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(tone == .unknown ? Theme.Palette.textSecondary : tone.color)
                .accessibilityHidden(true)
        }
    }
}

// #490: primary button chrome stays with OlcButton and the shared Signal palette.

/// Native management rows reuse the exact host menu closures, including
/// their original roles and custom bot asset; they do not reimplement actions.
struct ServerManagementMenuRows: View {
    let items: [OlcMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if case let .button(role, action) = item.kind {
                Button(role: role, action: action) {
                    if let asset = item.assetImage {
                        Label {
                            Text(item.title).font(Theme.Typography.body)
                        } icon: {
                            Image(asset).renderingMode(.template)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    } else {
                        SignalSettingsLabel(item.title, systemImage: item.systemImage ?? "chevron.right")
                    }
                }
            }
        }
    }
}

/// #490 was: blue wrapping chips in the server editors. Keep the exact
/// OlcOption values, availability and bindings, but use full-width native
/// rows: a choice is named, its selection is explicit, and long labels wrap.
struct ServerSignalOptions<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [OlcOption<Value>]

    init(selection: Binding<Value>, options: [OlcOption<Value>]) {
        self._selection = selection
        self.options = options
    }

    init(selection: Binding<Value>, options: [(Value, String)]) {
        self._selection = selection
        self.options = options.map { OlcOption(value: $0.0, label: $0.1) }
    }

    var body: some View {
        ForEach(options) { option in
            optionRow(option)
        }
    }

    private func optionRow(_ option: OlcOption<Value>) -> some View {
        let selected = selection == option.value
        return Button {
            guard ServerPresentationPolicy.allowsSelectionChange(
                current: selection, proposed: option.value, isDisabled: option.disabled
            ) else { return }
            Haptics.tap()
            selection = option.value
        } label: {
            HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    Text(option.label)
                        .font(selected ? Theme.Typography.bodyStrong : Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if option.disabled, let reason = option.disabledReason {
                        Text(reason)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: selected
                      ? (option.disabled ? "exclamationmark.circle" : "checkmark.circle.fill")
                      : "circle")
                    .foregroundStyle(option.disabled ? Theme.Palette.textSecondary : Theme.Signal.stroke)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Metrics.controlHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(option.disabled)
        .accessibilityLabel(option.a11yLabel ?? option.label)
        .accessibilityHint(option.disabled ? (option.disabledReason ?? "") : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
// eoc #490
