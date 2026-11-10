import SwiftUI
import TouchpointCore

/// The suggested replies under an assistant message. Web draws these as ghost `TextButton`s stacked
/// with no gap inside a `TextButtonGroup` — full-width rows, label on the left and a `Send` glyph on
/// the right, not pills (`Messages.tsx:95-131`, `ui/TextButton.tsx`). Once a choice is picked only
/// that one remains, disabled, and it is echoed as a user message.
///
/// The SDK draws them; the host supplies the strings and decides what a tap means — normally
/// `session.send(_:)`.
@MainActor
public struct TouchpointSuggestedReplies: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    private let replies: [String]
    private let chosen: String?
    private let onSelect: (String) -> Void

    /// - Parameters:
    ///   - replies: The suggestions, in the order the flow offered them.
    ///   - chosen: The reply already taken. As web does, only that row stays on screen once a choice
    ///     is made, and it is no longer tappable.
    ///   - onSelect: What a tap means.
    public init(_ replies: [String], chosen: String? = nil, onSelect: @escaping (String) -> Void) {
        self.replies = replies
        self.chosen = chosen
        self.onSelect = onSelect
    }

    private var metrics: TranscriptMetrics { TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme) }

    /// What the group shows: every suggestion, or just the one taken.
    static func visible(_ replies: [String], chosen: String?) -> [String] {
        guard let chosen else { return replies }
        return replies.contains(chosen) ? [chosen] : []
    }

    public var body: some View {
        let rows = Self.visible(replies, chosen: chosen)
        VStack(spacing: 0) {
            // Indexed, so two identical suggestions do not collide on `id` — and so a row knows
            // whether it is the first, which is what decides the divider.
            ForEach(Array(rows.enumerated()), id: \.offset) { index, reply in
                Button { onSelect(reply) } label: {
                    HStack(spacing: metrics.controlPadding) {
                        Text(reply)
                            .font(metrics.bodyFont)
                            .foregroundStyle(theme.primary(.t90))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        // Web's choice rows carry the Send icon at 16, the size of the composer's (QA c42).
                        TouchpointIconView(.send, size: metrics.iconGlyphSize)
                            .foregroundStyle(theme.primary(.t90))
                    }
                    .padding(.horizontal, metrics.textButtonHorizontalPadding)
                    .padding(.vertical, metrics.textButtonVerticalPadding)
                    .frame(maxWidth: .infinity)
                    // No per-row fill. Web's grouped ghost button paints nothing of its own and is
                    // separated from the row above by a hairline inset to the label's leading edge
                    // (`ui/TextButton.tsx:71`: `not-first:after:inset-x-5 … h-px … bg-primary-10`).
                    // Painting each row as its own filled, individually-rounded pill instead — which
                    // is what this did — stacked three identical shapes with nothing between them,
                    // and the group read as a single blob rather than three choices.
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle()
                                .fill(theme.primary(.t10))
                                .frame(height: metrics.hairline)
                                .padding(.horizontal, metrics.textButtonHorizontalPadding)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(chosen != nil)
                .accessibilityAddTraits(chosen == reply ? .isSelected : [])
                // The hint promises a tap sends the text; once a reply is taken that is a lie.
                .accessibilityHint(chosen == nil ? TouchpointStrings.suggestedReplyHint : "")
            }
        }
        .background(theme.primary(.t5), in: TouchpointShape.rounded(metrics.outerRadius))
        // Clipped, so the first and last rows take their corners from the group — web's
        // `first:rounded-t-outer last:rounded-b-outer` — and a press highlight cannot square them off.
        .clipShape(TouchpointShape.rounded(metrics.outerRadius))
        .overlay {
            TouchpointShape.rounded(metrics.outerRadius)
                .strokeBorder(theme.primary(.t10), lineWidth: metrics.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TouchpointStrings.suggestedRepliesLabel)
    }
}
