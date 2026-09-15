import SwiftUI

// MARK: - FormField
//
// The ONE labelled input for every editor sheet and wizard step: caption label
// above, a visible field plate (`Palette.fill` + `fillBorder` hairline, 44pt
// floor) holding the text, an optional helper line below, and — for secrets —
// the reveal toggle INSIDE the plate on the trailing edge.
//
// Round 2 was: a bare `SecureField(placeholder, …)` beside an eye glyph, with
// no plate and (at two call sites) an empty placeholder — so "Account token"
// and "Key (hex)" rendered as an empty row with a lone eye. Every field now
// draws its own surface, an empty placeholder falls back to the label, and the
// SecureField ↔ TextField swap shares one binding and hands focus back.

struct FormField: View {
    let label       : String
    let placeholder : String
    @Binding var text: String
    var secure      : Bool = false
    var keyboard    : UIKeyboardType = .default
    var focusBinding: FocusState<Bool>.Binding? = nil
    /// Monospaced value: hex keys, tokens, room ids, URLs.
    var mono        : Bool = false
    /// One caption line under the plate, in `textSecondary`.
    var helper      : String? = nil

    @State private var isRevealed: Bool = false
    /// Owned focus for the secure path, so revealing/hiding can give the
    /// keyboard back to the field that replaced the one the user was typing in.
    @FocusState private var secureFocused: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous)
    }

    /// An empty placeholder used to render an invisible field; the label is
    /// always a meaningful fallback.
    private var displayPlaceholder: String {
        placeholder.isEmpty ? label : placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Metrics.s2) {
                input
                    .font(mono ? Theme.Typography.metricValue : Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.controlHeight)
                if secure {
                    revealToggle
                }
            }
            .padding(.leading, Theme.Metrics.s3)
            .padding(.trailing, secure ? Theme.Metrics.s1 : Theme.Metrics.s3)
            .background(Theme.Palette.fill, in: shape)
            .overlay { shape.strokeBorder(Theme.Palette.fillBorder, lineWidth: 1) }

            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Input

    @ViewBuilder
    private var input: some View {
        if secure {
            secureInput
        } else if let fb = focusBinding {
            TextField(displayPlaceholder, text: $text)
                .keyboardType(keyboard)
                .focused(fb)
                .accessibilityLabel(label)
        } else {
            TextField(displayPlaceholder, text: $text)
                .keyboardType(keyboard)
                .accessibilityLabel(label)
        }
    }

    /// Both branches bind the same `$text` and the same focus state, so a
    /// reveal never drops typed characters and `toggleReveal` can re-focus.
    @ViewBuilder
    private var secureInput: some View {
        if isRevealed {
            TextField(displayPlaceholder, text: $text)
                .keyboardType(keyboard)
                .focused($secureFocused)
                .accessibilityLabel(label)
        } else {
            SecureField(displayPlaceholder, text: $text)
                .focused($secureFocused)
                .accessibilityLabel(label)
        }
    }

    private var revealToggle: some View {
        Button(action: toggleReveal) {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: Theme.Metrics.controlHeight, height: Theme.Metrics.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((isRevealed ? L10n.fieldHideSecret : L10n.fieldRevealSecret).localized())
    }

    /// Swapping SecureField ↔ TextField replaces the focused view; if the user
    /// was typing, hand focus to the replacement on the next run-loop turn.
    private func toggleReveal() {
        let wasFocused = secureFocused
        isRevealed.toggle()
        if wasFocused {
            DispatchQueue.main.async { secureFocused = true }
        }
    }
}

// MARK: - FormNote
//
// A small tinted note under a control: a tone glyph plus one caption line on a
// soft wash of the same tone. Used for the transport recommendation / warning
// under the chip pickers instead of a lone "★ …" caption. `tone == nil` is a
// neutral informational note on the standard fill.

struct FormNote: View {
    let text: String
    var tone: OlcStatusTone? = nil

    private var color: Color {
        tone?.color ?? Theme.Palette.textSecondary
    }

    private var symbol: String {
        tone?.symbol ?? "info.circle"
    }

    private var wash: Color {
        tone == nil ? Theme.Palette.fill : color.opacity(0.12)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s2) {
            Image(systemName: symbol)
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(FormNoteText.stripMarker(text))
                .font(Theme.Typography.caption)
                .foregroundStyle(tone == nil ? Theme.Palette.textSecondary : color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Metrics.s3)
        .padding(.vertical, Theme.Metrics.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
    }
}

/// Pure text helpers for `FormNote` (unit-tested in Tests/FormFieldTests.swift).
enum FormNoteText {
    /// The matrix strings (`matrixRecommended_fmt` & co.) open with a ★ / ⚠ / ✗
    /// marker that other screens still draw as plain text. Inside a `FormNote`
    /// the tone glyph already carries that meaning, so the marker is dropped.
    static let markers: Set<Character> = ["★", "☆", "⚠", "✗", "✓", "•"]

    static func stripMarker(_ text: String) -> String {
        // Work on scalars, not Characters: "⚠" + U+FE0F is ONE grapheme, so a
        // Character-level compare would never match the bare marker.
        let markerScalars = Set(markers.flatMap { $0.unicodeScalars })
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, markerScalars.contains(first) || first.value == 0xFE0F {
            scalars = scalars.dropFirst()
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}

#if DEBUG
#Preview("FormField — Dark") {
    Form {
        Section {
            FormField(label: "Name", placeholder: "My server", text: .constant(""))
            FormField(label: "Room ID", placeholder: "Paste the room id", text: .constant("352854101234"),
                      mono: true, helper: "A Telemost meeting link works too — it is shortened to the id.")
            FormField(label: "Key (hex)", placeholder: "64 hex characters", text: .constant(""),
                      secure: true, mono: true)
            FormNote(text: "★ Recommended for WB Stream.", tone: .ok)
            FormNote(text: "⚠ Working with Telemost is uncertain.", tone: .warn)
            FormNote(text: "Shares the key with the installed protocols.")
        }
        .signalFormRows()
    }
    .signalFormChrome()
    .preferredColorScheme(.dark)
}
#endif
