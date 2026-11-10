import SwiftUI

/// The conversation's three parts: the content (the welcome group, or the transcript), the choices,
/// and the composer. One layout hosts both the welcome screen and the transcript, so the composer
/// keeps its identity, its focus and the keyboard when the first message turns the one into the
/// other (c53). Each child is tagged with its ``Role``.
///
/// - **Transcript:** the content takes what the choices and the composer leave; then the choices,
///   then the composer at the bottom.
/// - **Welcome, inline:** when everything fits, web's arrangement (`App.tsx`, welcome branch): the
///   greeting, the composer under it, and the choices under that, centred as one group.
/// - **Welcome, pinned:** when it doesn't fit (a short panel, large text, the keyboard up, a long
///   draft), the transcript's arrangement, with the greeting centred in what is left and scrolling
///   if it needs to. The composer then sits at the bottom, just above the keyboard, and grows
///   upwards; it is never clipped. **Deviation:** web leaves overflow to the page and the browser.
struct ConversationLayout: Layout {
    enum Role { case content, accessory, composer }
    struct RoleKey: LayoutValueKey { static let defaultValue: Role = .content }

    var isWelcome: Bool
    /// Above the choices when they sit over the composer.
    var accessorySpacing: CGFloat
    /// Between the welcome content and the composer when inline.
    var welcomeGap: CGFloat

    struct Arrangement: Equatable {
        var content: ClosedRange<CGFloat>
        var accessory: ClosedRange<CGFloat>?
        var composer: ClosedRange<CGFloat>?
        var isInline: Bool
    }

    /// Where each part goes, as vertical spans in a panel `height` tall. `content` is the content's
    /// natural height (only read on the welcome screen); `accessory` and `composer` are `nil` when
    /// the part is absent.
    static func arrange(height: CGFloat, content: CGFloat, accessory: CGFloat?, composer: CGFloat?,
                        isWelcome: Bool, accessorySpacing: CGFloat, welcomeGap: CGFloat) -> Arrangement {
        let inlineTotal = content + (composer.map { welcomeGap + $0 } ?? 0) + (accessory ?? 0)
        if isWelcome, accessory != nil, composer != nil, inlineTotal <= height {
            var y = (height - inlineTotal) / 2
            let contentSpan = y...(y + content)
            y += content
            var composerSpan: ClosedRange<CGFloat>?
            if let composer {
                y += welcomeGap
                composerSpan = y...(y + composer)
                y += composer
            }
            // No gap after the composer: its own outer padding is web's `space-y-2` (8pt) between
            // the input and the choices. Adding `accessorySpacing` here made it 16, which is c44.
            let accessorySpan = accessory.map { y...(y + $0) }
            return Arrangement(content: contentSpan, accessory: accessorySpan, composer: composerSpan, isInline: true)
        }
        // The composer first, then the choices in what it leaves, then the content: the composer
        // is never clipped, and the choices and the content scroll in less than they would like.
        var bottom = height
        var composerSpan: ClosedRange<CGFloat>?
        if let composer {
            let top = max(0, bottom - composer)
            composerSpan = top...bottom
            bottom = top
        }
        var accessorySpan: ClosedRange<CGFloat>?
        if let accessory {
            let room = max(0, bottom - accessorySpacing)
            let top = bottom - min(accessory, room)
            accessorySpan = top...bottom
            bottom = max(0, top - accessorySpacing)
        }
        let region = 0...bottom
        guard isWelcome else {
            return Arrangement(content: region, accessory: accessorySpan, composer: composerSpan, isInline: false)
        }
        let used = min(content, bottom)
        let top = (bottom - used) / 2
        return Arrangement(content: top...(top + used), accessory: accessorySpan, composer: composerSpan, isInline: false)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        if let height = proposal.height { return CGSize(width: width, height: height) }
        let natural = ProposedViewSize(width: width, height: nil)
        let roles = Set(subviews.map { $0[RoleKey.self] })
        // The same gaps `arrange` puts between the parts, so a host that offers no height gets
        // back room for the inline arrangement rather than 8–16pt less.
        // Welcome with a composer: only `welcomeGap` (the composer's own padding is the gap to
        // the choices). Otherwise `accessorySpacing` above the choices.
        let gaps: CGFloat = isWelcome && roles.contains(.composer)
            ? welcomeGap
            : (roles.contains(.accessory) ? accessorySpacing : 0)
        return CGSize(width: width, height: gaps + subviews.reduce(0) { $0 + $1.sizeThatFits(natural).height })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let natural = ProposedViewSize(width: bounds.width, height: nil)
        let content = subviews.first { $0[RoleKey.self] == .content }
        let accessory = subviews.first { $0[RoleKey.self] == .accessory }
        let composer = subviews.first { $0[RoleKey.self] == .composer }
        let arrangement = Self.arrange(
            height: bounds.height,
            content: isWelcome ? (content?.sizeThatFits(natural).height ?? 0) : 0,
            accessory: accessory?.sizeThatFits(natural).height,
            composer: composer?.sizeThatFits(natural).height,
            isWelcome: isWelcome, accessorySpacing: accessorySpacing, welcomeGap: welcomeGap)
        func place(_ subview: LayoutSubview?, _ span: ClosedRange<CGFloat>?) {
            guard let subview, let span else { return }
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + span.lowerBound), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: span.upperBound - span.lowerBound))
        }
        place(content, arrangement.content)
        place(accessory, arrangement.accessory)
        place(composer, arrangement.composer)
    }
}
