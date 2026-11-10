import SwiftUI

public extension TouchpointVoiceMiniRail {
    /// Lets the customer drag the rail around the space it is given, as web's voice mini widget
    /// (`useDraggable`): it keeps its `anchor` and moves by an offset, clamped so it stays wholly
    /// inside, 8pt from every edge of that space (the safe area, unless the host ignores it). No
    /// snapping, and the position is not remembered across launches — web does neither.
    ///
    /// The rail then draws web's drag handle and starts a drag only from it, so its buttons keep
    /// their taps. Put it in a layer that spans the screen — an overlay on the host's root — since
    /// it can travel only within the space it is proposed, and keep that layer mounted (hide it
    /// rather than remove it) if the position should survive the chat opening. The layer takes no
    /// touches of its own: only the rail does.
    ///
    /// Call it on the rail itself, before any other modifier; what it returns is the full-screen
    /// layer, so view modifiers after it (an accessibility identifier, say) apply to that layer.
    ///
    /// Left-to-right layouts only for now: the SDK ships English only, and right-to-left drag
    /// direction is unverified.
    func touchpointDraggable(anchor: Alignment = .bottomTrailing) -> some View {
        modifier(DraggableModifier(anchor: anchor))
    }
}

/// What the rail's handle reports to the modifier that owns the offset.
struct DragHandling {
    var changed: @MainActor (CGSize) -> Void
    var ended: @MainActor () -> Void
}

private struct DragHandlingKey: EnvironmentKey {
    static let defaultValue: DragHandling? = nil
}

extension EnvironmentValues {
    var touchpointDrag: DragHandling? {
        get { self[DragHandlingKey.self] }
        set { self[DragHandlingKey.self] = newValue }
    }
}

/// The offset rule, pure so it is testable: web's clamp, with the anchor's own margin built into
/// the base position (web's `bottom-2 right-2`).
enum Draggable {
    static let margin: CGFloat = 8

    static func clamp(_ offset: CGSize, content: CGSize, container: CGSize, anchor: Alignment) -> CGSize {
        guard content.width > 0, container.width > 0 else { return .zero }
        func axis(_ value: CGFloat, size: CGFloat, room: CGFloat, base: CGFloat) -> CGFloat {
            let low = margin - base
            let high = room - margin - size - base
            // Bigger than the room: stay at the anchor rather than invert the range.
            guard high >= low else { return min(max(0, low), max(0, high)) }
            return min(max(value, low), high)
        }
        return CGSize(
            width: axis(offset.width, size: content.width, room: container.width,
                        base: base(content.width, room: container.width, along: anchor.horizontal)),
            height: axis(offset.height, size: content.height, room: container.height,
                         base: base(content.height, room: container.height, along: anchor.vertical)))
    }

    /// Where the content sits with no offset, from the container's leading/top edge.
    private static func base(_ size: CGFloat, room: CGFloat, along alignment: HorizontalAlignment) -> CGFloat {
        switch alignment {
        case .leading: margin
        case .trailing: room - margin - size
        default: (room - size) / 2
        }
    }

    private static func base(_ size: CGFloat, room: CGFloat, along alignment: VerticalAlignment) -> CGFloat {
        switch alignment {
        case .top: margin
        case .bottom: room - margin - size
        default: (room - size) / 2
        }
    }
}

/// Owns the offset, so it survives the rail redrawing (and stays put while the host keeps this
/// layer mounted). The drawn position follows either size as it changes — rotation, Dynamic Type,
/// a control appearing on the rail, the container shrinking — without forgetting the asked one.
private struct DraggableModifier: ViewModifier {
    let anchor: Alignment
    /// Where the customer put the rail, kept as asked: it is clamped where it is drawn, never in
    /// place, so a container that shrinks for a while — the phone's half chat insetting the
    /// screen, a keyboard — and grows back returns the rail where it was.
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var contentSize: CGSize = .zero
    @State private var containerSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .environment(\.touchpointDrag, DragHandling(
                changed: { translation in
                    // From where the rail is drawn, so a drag never has to undo an overshoot first.
                    let start = dragStart ?? clamped(offset)
                    dragStart = start
                    offset = clamped(CGSize(width: start.width + translation.width, height: start.height + translation.height))
                },
                ended: { dragStart = nil }))
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { contentSize = $0 }
            .offset(clamped(offset))
            .padding(Draggable.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { containerSize = $0 }
    }

    private func clamped(_ proposed: CGSize) -> CGSize {
        Draggable.clamp(proposed, content: contentSize, container: containerSize, anchor: anchor)
    }
}
