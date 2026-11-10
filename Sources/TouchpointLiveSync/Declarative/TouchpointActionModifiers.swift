#if canImport(SwiftUI)
import SwiftUI
import TouchpointCore

// MARK: - Preference plumbing

/// Aggregates every `.touchpointAction` beneath a view into one set.
struct TouchpointActionsPreferenceKey: PreferenceKey {
    static let defaultValue = TouchpointActionSet()
    static func reduce(value: inout TouchpointActionSet, nextValue: () -> TouchpointActionSet) {
        value.merge(nextValue())
    }
}

/// The nearest enclosing `.touchpointScope`, read by `.touchpointAction` so a declaration carries
/// its scope without repeating it.
private struct TouchpointScopeKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var touchpointScope: String? {
        get { self[TouchpointScopeKey.self] }
        set { self[TouchpointScopeKey.self] = newValue }
    }
}

private struct TouchpointActionModifier: ViewModifier {
    @Environment(\.touchpointScope) private var scope
    let name: String
    let description: String
    let schema: JSONValue
    let confirmationRequired: Bool
    let confirmationMessage: String?
    let handler: @MainActor @Sendable (JSONValue) throws -> Void

    func body(content: Content) -> some View {
        // Merge into what the content already declares. `.preference(key:value:)` *replaces* the
        // value of the view it is applied to, so two `.touchpointAction`s chained on one view kept
        // only the outer one — the transactions screen advertised `select_transaction` and lost
        // `filter_transactions`. Inner declarations are listed last so they win a name clash, as
        // the most specific view should.
        let declaration = TouchpointActionDeclaration(name, description: description, schema: schema, scope: scope,
                                                      confirmationRequired: confirmationRequired,
                                                      confirmationMessage: confirmationMessage, rawHandler: handler)
        return content.transformPreference(TouchpointActionsPreferenceKey.self) { value in
            value = TouchpointActionSet([declaration] + value.declarations)
        }
    }
}

// MARK: - Public modifiers

extension View {
    /// Declares an action the voice assistant may invoke **while this view is in the tree**. When
    /// the view goes away the action is withdrawn; when it appears the action is advertised. No
    /// imperative call anywhere: the visible tree *is* the context.
    ///
    /// The payload type is inferred from the handler, and its schema travels with it, so what the
    /// SDK validates against on the device and what the handler decodes are the same declaration:
    ///
    /// ```swift
    /// DisputeForm(model: model)
    ///     .touchpointAction("set_dispute_details",
    ///                       description: "Fill in the dispute form with what the customer said") {
    ///         (details: DisputeDetails) in model.apply(details)
    ///     }
    /// ```
    ///
    /// Action names never enter the accessibility tree. The prior art pushed integrators to put
    /// machine identifiers in `accessibilityLabel`, so VoiceOver read `"NumPassengers"` aloud; here the
    /// declaration is a preference, invisible to assistive technology, and the view keeps whatever
    /// human label it has.
    ///
    /// Declare only what the customer can undo: never a payment, a transfer or a submission; leave
    /// that last step to the customer's own tap. Pass `confirmationRequired: true` for a reversible
    /// action the customer should see coming: an invocation is then held and the customer
    /// asked to allow it before the handler runs. It does not make an irreversible action safe to
    /// declare. Pair it with
    /// `.touchpointActionConfirmation(_:)` (or your own UI driven by
    /// ``LiveSyncClient/onPendingConfirmationChange``). `confirmationMessage` overrides the default
    /// prompt body, which is otherwise `description`.
    public func touchpointAction<Payload: TouchpointActionPayload>(
        _ name: String,
        description: String,
        confirmationRequired: Bool = false,
        confirmationMessage: String? = nil,
        handler: @escaping @MainActor @Sendable (Payload) throws -> Void
    ) -> some View {
        modifier(TouchpointActionModifier(name: name, description: description, schema: Payload.schema,
                                          confirmationRequired: confirmationRequired,
                                          confirmationMessage: confirmationMessage) { json in
            try handler(try json.decode(Payload.self))
        })
    }

    /// A parameterless action.
    public func touchpointAction(
        _ name: String,
        description: String,
        confirmationRequired: Bool = false,
        confirmationMessage: String? = nil,
        handler: @escaping @MainActor @Sendable () throws -> Void
    ) -> some View {
        modifier(TouchpointActionModifier(name: name, description: description, schema: TouchpointNoPayload.schema,
                                          confirmationRequired: confirmationRequired,
                                          confirmationMessage: confirmationMessage) { _ in
            try handler()
        })
    }

    /// An action whose schema is supplied by hand — for a contract file shared with the backend.
    public func touchpointAction(
        _ name: String,
        description: String,
        schema: JSONValue,
        confirmationRequired: Bool = false,
        confirmationMessage: String? = nil,
        handler: @escaping @MainActor @Sendable (JSONValue) throws -> Void
    ) -> some View {
        modifier(TouchpointActionModifier(name: name, description: description, schema: schema,
                                          confirmationRequired: confirmationRequired,
                                          confirmationMessage: confirmationMessage, handler: handler))
    }

    /// Tags every action declared beneath this view with a scope — a tool-selection narrowing hint
    /// for the engine ("the customer is on the dispute screen"), not a separate state channel. Scopes
    /// are derived from visibility like actions: a screen off the tree contributes no scope.
    ///
    /// "Beneath" is literal: apply it **outside** the actions it covers — last in a modifier chain,
    /// or on a container. `.touchpointScope("x").touchpointAction(…)` puts the action outside the
    /// scope, so it carries none.
    public func touchpointScope(_ scope: String) -> some View {
        environment(\.touchpointScope, scope)
    }

    /// Binds the declarative actions beneath this view to a Live Sync client. Put it once, at the
    /// root of the tree that declares actions. Every `.touchpointAction` below is aggregated,
    /// debounced and advertised, and every invocation the client receives is routed to the handler
    /// that declared it.
    public func touchpointLiveSync(_ aggregator: TouchpointActionAggregator) -> some View {
        onPreferenceChange(TouchpointActionsPreferenceKey.self) { set in
            // SwiftUI delivers this on the main thread today, but the closure is `@Sendable` and
            // that is not a documented guarantee. Hop rather than assert: `assumeIsolated` would
            // trap the host app on an off-main delivery. The aggregator debounces, so the hop's
            // turn of latency is absorbed.
            Task { @MainActor in aggregator.update(set) }
        }
    }
    /// Collapses a chat when the assistant acts on the app, so the customer sees what changed
    /// before they answer. **Opt-in** — nothing collapses unless a host adds this, and `isEnabled`
    /// lets it be a user setting. The collapse is announced to VoiceOver, whose focus was in the chat.
    ///
    /// ```swift
    /// RootView()
    ///     .touchpointCollapsesOnAssistantAction($chatPresented, aggregator: liveSync.aggregator)
    /// ```
    ///
    /// Pair it with a chat that stays mounted while hidden (`touchpointChatWindow`), or the
    /// customer's half-typed message goes with it.
    public func touchpointCollapsesOnAssistantAction(_ isPresented: Binding<Bool>,
                                                     aggregator: TouchpointActionAggregator,
                                                     isEnabled: Bool = true) -> some View {
        // Keyed on the aggregator too: a host that builds a new one per connection changes the
        // count without the assistant doing anything, and that must not collapse the chat.
        onChange(of: RoutedCount(aggregator: ObjectIdentifier(aggregator), count: aggregator.routedInvocations)) { old, new in
            guard old.aggregator == new.aggregator, new.count > old.count,
                  isEnabled, isPresented.wrappedValue else { return }
            isPresented.wrappedValue = false
            AccessibilityNotification.Announcement(TouchpointStrings.liveSyncCollapsedAnnouncement).post()
        }
    }

    /// Presents the SDK's confirmation prompt for actions a declaration marked
    /// `confirmationRequired: true`. Put it once, near the root of the tree bound with
    /// `.touchpointLiveSync`. While `client.pendingConfirmation` is set it shows a
    /// `.confirmationDialog` titled "Allow the assistant to do this?" with the action's description
    /// (or a host `confirmationMessage`) as the body and Allow / Cancel buttons; Allow runs the
    /// held handler, Cancel (or dismissing the sheet) drops it.
    ///
    /// It owns the client's ``LiveSyncClient/onPendingConfirmationChange`` callback. A host that
    /// wants its own confirmation UI should set that callback itself and not apply this modifier.
    public func touchpointActionConfirmation(_ client: LiveSyncClient) -> some View {
        modifier(TouchpointActionConfirmationModifier(client: client))
    }
}

/// Bridges the client's (non-`Observable`) ``LiveSyncClient/pendingConfirmation`` into SwiftUI
/// state via its change callback, and presents the prompt.
private struct TouchpointActionConfirmationModifier: ViewModifier {
    let client: LiveSyncClient
    @State private var pending: LiveSyncClient.PendingConfirmation?

    func body(content: Content) -> some View {
        content
            .onAppear {
                pending = client.pendingConfirmation
                client.onPendingConfirmationChange = { pending = $0 }
            }
            .confirmationDialog(
                TouchpointStrings.liveSyncConfirmTitle,
                isPresented: Binding(
                    get: { pending != nil },
                    // Dismissing the sheet without choosing Allow is a cancel. Guarded so the
                    // button paths (which clear `pending` first) do not decline a second time.
                    set: { presented in if !presented, pending != nil { client.cancelPendingAction() } }
                ),
                titleVisibility: .visible,
                presenting: pending
            ) { _ in
                Button(TouchpointStrings.liveSyncConfirmAllow) { client.confirmPendingAction() }
                Button(TouchpointStrings.liveSyncConfirmCancel, role: .cancel) { client.cancelPendingAction() }
            } message: { confirmation in
                if let message = confirmation.message {
                    Text(message)
                } else if let description = confirmation.actionDescription {
                    Text(description)
                }
            }
    }
}

private struct RoutedCount: Equatable {
    let aggregator: ObjectIdentifier
    let count: Int
}

// MARK: - Debug overlay ("the natural proof that the aggregation works")

#if DEBUG
/// Shows what the tree is declaring and what has been advertised. Debug builds only; the showcase
/// runs with it visible so the audience watches the advertised set change as screens change.
public struct TouchpointLiveSyncOverlay: View {
    private let aggregator: TouchpointActionAggregator
    private let connectionState: LiveSyncConnectionState?
    private let dispatchState: DispatchState?
    private let noteFrames: Int
    @ScaledMetric(relativeTo: .caption) private var spacing = 4
    @ScaledMetric(relativeTo: .caption) private var inset = 8

    public init(aggregator: TouchpointActionAggregator, client: LiveSyncClient? = nil) {
        self.aggregator = aggregator
        self.connectionState = client?.connectionState
        self.dispatchState = client?.dispatchState
        self.noteFrames = client?.diagnostics.noteFrames ?? 0
    }

    public var body: some View {
        // Developer diagnostics in composed, non-localised text — not product copy (the string catalog applies to
        // user-facing strings; this view is `accessibilityHidden` and debug-only).
        let status = Self.statusLine(connection: connectionState, dispatch: dispatchState, posts: aggregator.postCount)
        let traffic = Self.trafficLine(notes: noteFrames, unrouted: aggregator.unroutedInvocations,
                                      lastAction: aggregator.lastInvocation?.action)
        let detail = Self.detailLines(aggregator).joined(separator: "\n")
        VStack(alignment: .leading, spacing: spacing) {
            Text("\(status)").font(.caption.monospaced()).bold()
            Text("\(traffic)").font(.caption2.monospaced())
            Text("\(detail)").font(.caption2.monospaced())
        }
        .padding(inset)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: inset))
        // Developer tooling, not product UI: hidden from assistive technology so VoiceOver never
        // reads action names aloud — the exact failure the API exists to avoid.
        .accessibilityHidden(true)
        // Same reasoning applied to touch. The overlay carries no controls, and it sits over the
        // host's own chrome (top-trailing is where a toolbar button lives), so without this it
        // silently swallows taps on whatever it covers — diagnostics must not intercept product
        // interaction.
        .allowsHitTesting(false)
    }

    /// Pure formatting, so a test can assert the overlay's text without rendering.
    static func statusLine(connection: LiveSyncConnectionState?, dispatch: DispatchState?, posts: Int) -> String {        let c: String
        switch connection {
        case .idle?: c = "idle"
        case .connecting?: c = "connecting"
        case .connected?: c = "connected"
        case .reconnecting(let n)?: c = "reconnecting #\(n)"
        case .disconnected?: c = "disconnected"
        case nil: c = "no client"
        }
        let d = dispatch == .suspended ? " · dispatch SUSPENDED" : ""
        return "Live Sync: \(c)\(d) · \(posts) post\(posts == 1 ? "" : "s")"
    }

    /// The inbound half: what the socket actually delivered. Separates "the engine is saying things
    /// but routing nothing" (notes climbing, unrouted climbing) from "the engine is silent" (both
    /// flat) — the two failure modes that otherwise look identical from the status line alone.
    static func trafficLine(notes: Int, unrouted: Int, lastAction: String?) -> String {
        var parts = ["\(notes) note\(notes == 1 ? "" : "s")"]
        if unrouted > 0 { parts.append("\(unrouted) UNROUTED") }
        parts.append("last: \(lastAction ?? "—")")
        return parts.joined(separator: " · ")
    }

    static func scopeLine(_ set: TouchpointActionSet) -> String {
        "scopes: \(set.scopes?.joined(separator: ", ") ?? "—") · \(set.declarations.count) action\(set.declarations.count == 1 ? "" : "s")"
    }

    /// Advertised names, pending (declared but not yet posted) names, and the last invocation.
    static func detailLines(_ a: TouchpointActionAggregator) -> [String] {
        var lines = [scopeLine(a.advertised)]
        lines += a.advertised.declarations.map { "• \($0.name)" + (a.current[$0.name] == nil ? " (withdrawn)" : "") }
        lines += a.current.declarations.filter { a.advertised[$0.name] == nil }.map { "+ \($0.name) (pending)" }
        if let last = a.lastInvocation { lines.append("← \(last.action) \(last.payload)") }
        return lines
    }
}
#endif
#endif
