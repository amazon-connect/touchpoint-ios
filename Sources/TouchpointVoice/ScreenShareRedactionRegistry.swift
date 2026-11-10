#if canImport(UIKit)
import CoreGraphics
import SwiftUI
import UIKit

// MARK: - Public screen-share masking API
//
// The smallest coherent surface: mark a view to black it out of the shared frame, or mark it
// "secure" to blank the whole frame while it is visible. SwiftUI gets two modifiers; UIKit gets a
// small registry. Marks are kept with weak references, so a view the host releases is forgotten —
// a host need not un-mark, though UIKit callers may. Marks take effect only while a screen share is
// running; with nothing marked, the shared frame is exactly today's.

/// Mark UIKit views for screen-share redaction. Main-actor: call from the view's own context.
@MainActor
public enum TouchpointScreenShare {
    /// Black this view's rectangle out of every shared frame while it is on screen.
    public static func redact(_ view: UIView) { RedactionCoordinator.shared.add(view, kind: .redacted) }

    /// Blank the **whole** shared frame while this view is on screen — the iOS `FLAG_SECURE`
    /// equivalent. Use for a screen whose mere layout is sensitive.
    public static func secure(_ view: UIView) { RedactionCoordinator.shared.add(view, kind: .secure) }

    /// Stop redacting / securing a view marked earlier. Optional — a released view drops itself.
    public static func stop(_ view: UIView) { RedactionCoordinator.shared.remove(view) }
}

public extension View {
    /// Black this view's rectangle out of every screen-share frame while it is on screen.
    func touchpointScreenShareRedacted() -> some View {
        modifier(ScreenShareRedactionModifier(kind: .redacted))
    }

    /// Blank the **whole** screen-share frame while this view is on screen — the iOS `FLAG_SECURE`
    /// equivalent.
    func touchpointScreenShareSecure() -> some View {
        modifier(ScreenShareRedactionModifier(kind: .secure))
    }
}

/// Tracks the view's global frame and (de)registers it with the coordinator for its lifetime.
struct ScreenShareRedactionModifier: ViewModifier {
    let kind: RedactionCoordinator.Kind
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                // `.global` is the window/screen space the coordinator scales against — the same
                // space UIKit's `convert(_:to: window)` reports.
                Color.clear
                    .onAppear { update(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in update(frame) }
                    .onDisappear { RedactionCoordinator.shared.removeSwiftUI(id) }
            }
        )
    }

    private func update(_ frame: CGRect) {
        RedactionCoordinator.shared.updateSwiftUI(id, frame: frame, kind: kind)
    }
}

// MARK: - Coordinator

/// Collects host-marked views and, while a share is running, snapshots their rectangles (in screen
/// points) into `RedactionSnapshotStore` on every display refresh. All work is on the main actor;
/// the capture queue only reads the snapshot.
@MainActor
final class RedactionCoordinator {
    static let shared = RedactionCoordinator()

    enum Kind: Equatable { case redacted, secure }

    private struct UIKitEntry { let box: WeakViewBox; let kind: Kind }
    private struct SwiftUIEntry { var frame: CGRect; var kind: Kind }

    private var uiKitEntries: [UIKitEntry] = []
    private var swiftUIEntries: [UUID: SwiftUIEntry] = [:]
    private var previousRects: [CGRect] = []
    private var capturing = false
    private var displayLink: CADisplayLink?
    private let store = RedactionSnapshotStore.shared

    // MARK: Registration

    func add(_ view: UIView, kind: Kind) {
        uiKitEntries.removeAll { $0.box.object === view || !$0.box.isAlive }
        uiKitEntries.append(UIKitEntry(box: WeakViewBox(view), kind: kind))
        refresh()
    }

    func remove(_ view: UIView) {
        uiKitEntries.removeAll { $0.box.object === view || !$0.box.isAlive }
        refresh()
    }

    func updateSwiftUI(_ id: UUID, frame: CGRect, kind: Kind) {
        swiftUIEntries[id] = SwiftUIEntry(frame: frame, kind: kind)
        refresh()
    }

    func removeSwiftUI(_ id: UUID) {
        swiftUIEntries[id] = nil
        refresh()
    }

    // MARK: Capture lifecycle (driven by the Chime driver)

    /// Begin or end snapshotting. While capturing, a display link keeps the rectangles fresh as
    /// views scroll or animate; stopping clears the snapshot so nothing lingers after a share.
    func setCapturing(_ on: Bool) {
        capturing = on
        if on {
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(displayTick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            refresh()
        } else {
            displayLink?.invalidate()
            displayLink = nil
            previousRects = []
            store.clear()
        }
    }

    @objc private func displayTick() { refresh() }

    // MARK: Snapshot

    private func refresh() {
        uiKitEntries.removeAll { !$0.box.isAlive }   // drop deallocated views
        guard capturing else { return }

        var rects: [CGRect] = []
        var secure = false
        let screenSize = keyWindowSize

        for entry in uiKitEntries {
            guard let view = entry.box.object as? UIView,
                  let window = view.window,
                  !view.isHidden, view.alpha > 0.01,
                  view.bounds.width > 0, view.bounds.height > 0 else { continue }   // hidden / off-window → drop
            if entry.kind == .secure {
                secure = true
            } else {
                rects.append(view.convert(view.bounds, to: window))
            }
        }
        for entry in swiftUIEntries.values {
            if entry.kind == .secure { secure = true } else { rects.append(entry.frame) }
        }

        guard !(rects.isEmpty && !secure) else {
            previousRects = []
            store.update(.none)
            return
        }

        // Union of previous and current rects: a frame captured between a view moving and this
        // snapshot updating is masked where the view was as well as where it is now.
        let union = rects + previousRects
        previousRects = rects
        store.update(ScreenShareRedaction(secure: secure, rects: union, screenSize: screenSize))
    }

    private var keyWindowSize: CGSize {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
                return window.bounds.size
            }
        }
        return .zero
    }
}
#endif
