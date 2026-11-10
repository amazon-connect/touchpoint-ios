import SwiftUI
import TouchpointCore

/// Web's `EndConversationConfirm` (`components/EndConversationConfirm.tsx`, 1.0.6): a card over a
/// `secondary` tier-60 veil, asking before the conversation ends. The settings panel's "End
/// conversation" and the header's added close (`AddedElement.HeaderClose`) both show it.
///
/// The card: `max-w-sm`, `p-4`, outer radius, the panel's `background` with a primary-10 border.
/// A title row (the 20pt `Warning` glyph and `text-xl` title, a ghost close that cancels), the
/// body at `text-sm`, then two full-width text buttons: cancel (subtle, `Close`) and confirm
/// (error, `LogOut`).
///
/// It replaces a system alert, which drew Apple's chrome instead of web's card. The veil takes
/// every touch, so the conversation under it cannot be used meanwhile, and VoiceOver treats the
/// card as modal with the escape gesture as cancel.
@MainActor
struct EndConversationConfirm: View {
    @Environment(\.touchpointTheme) private var theme
    let metrics: TranscriptMetrics
    let copy: (title: String, body: String, confirm: String, cancel: String)
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(theme.secondary(.t60))
                .contentShape(.rect)
                // Web's veil has no handler: a tap outside the card does nothing.
                .onTapGesture {}
                .accessibilityHidden(true)
            // Centred when it fits, as web's `items-center justify-center`; scrolls when it does not
            // (a short mini window, the largest text sizes).
            ViewThatFits(in: .vertical) {
                placedCard.frame(maxHeight: .infinity)
                ScrollView { placedCard }.scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var placedCard: some View {
        card
            .frame(maxWidth: metrics.confirmCardMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(metrics.confirmCardPadding)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: metrics.confirmSectionSpacing) {
            HStack(spacing: metrics.controlPadding) {
                TouchpointIconView(.warning, size: metrics.confirmWarningSize)
                    .accessibilityHidden(true)
                Text(copy.title)
                    .font(metrics.titleFont)
                    .foregroundStyle(theme.primary(.t90))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    // VoiceOver moves to the question, as it did into the system alert this
                    // replaces; otherwise it stays on the control that asked, or on nothing.
                    .accessibilityFocused($titleFocused)
                    .onAppear { titleFocused = true }
                Spacer(minLength: 0)
                Button(action: onCancel) { TouchpointIconView(.close) }
                    .buttonStyle(TouchpointIconButtonStyle(.ghost))
                    .accessibilityLabel(copy.cancel)
            }
            .foregroundStyle(theme.primary(.t90))
            Text(copy.body)
                .font(metrics.smallFont)
                .foregroundStyle(theme.primary(.t90))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: metrics.controlPadding) {
                Button(action: onCancel) { Text(copy.cancel) }
                    .buttonStyle(TouchpointTextButtonStyle(.subtle, icon: .close))
                    .accessibilityIdentifier(Self.cancelID)
                Button(action: onConfirm) { Text(copy.confirm) }
                    .buttonStyle(TouchpointTextButtonStyle(.error, icon: .logOut))
                    .accessibilityIdentifier(Self.confirmID)
            }
        }
        .padding(metrics.confirmCardPadding)
        // Web's `bg-background backdrop-blur-overlay`: the default background is translucent, so
        // the blur keeps the conversation under the card from showing through as text.
        .background {
            ZStack {
                TouchpointShape.rounded(metrics.outerRadius).fill(.ultraThinMaterial)
                TouchpointShape.rounded(metrics.outerRadius).fill(theme.background)
            }
        }
        .overlay {
            TouchpointShape.rounded(metrics.outerRadius)
                .strokeBorder(theme.primary(.t10), lineWidth: metrics.hairline)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        // On the card, a container: on a plain stack an identifier lands on every control in it.
        .accessibilityIdentifier(Self.accessibilityID)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onCancel)
    }

    static let accessibilityID = "touchpoint.endConfirm"
    static let cancelID = "touchpoint.endConfirm.cancel"
    static let confirmID = "touchpoint.endConfirm.confirm"
}
