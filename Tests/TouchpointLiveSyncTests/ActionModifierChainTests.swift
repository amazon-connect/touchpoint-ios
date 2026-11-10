#if canImport(SwiftUI)
import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

private struct Amount: TouchpointActionPayload, Equatable {
    var amount: Double?
    static let schema: JSONValue = .object(["type": "object", "properties": ["amount": ["type": "number"]]])
}

/// What the real modifiers put in the preference, read by rendering a view. The aggregator tests
/// build sets by hand, which is why two chained declarations losing one another went unnoticed: on
/// device the transactions screen advertised `select_transaction` and never `filter_transactions`.
@Suite("Action modifiers on a real view", .serialized)
@MainActor
struct ActionModifierChainTests {
    private final class Box { var set = TouchpointActionSet() }

    private func declared(_ view: some View) -> TouchpointActionSet {
        let box = Box()
        let root = view
            .frame(width: 100, height: 100)
            .onPreferenceChange(TouchpointActionsPreferenceKey.self) { set in
                MainActor.assumeIsolated { box.set = set }   // synchronous inside the render below
            }
        _ = ImageRenderer(content: root).cgImage
        return box.set
    }

    @Test("Two actions chained on one view are both declared, and a scope applied outside them tags both")
    func chainedActionsSurvive() {
        let set = declared(
            Color.clear
                .touchpointAction("filter_transactions", description: "filter") { (_: Amount) in }
                .touchpointAction("select_transaction", description: "select") { }
                .touchpointScope("transactions")
        )
        #expect(set.names == ["filter_transactions", "select_transaction"])
        #expect(set.scopes == ["transactions"])
    }

    @Test("Sibling screens merge, and a nested declaration of the same name wins over the outer one")
    func siblingsAndShadowing() {
        let set = declared(
            VStack {
                Color.clear.touchpointAction("open_account", description: "outer") { }
                Color.clear
                    .touchpointAction("start_dispute", description: "inner") { }
                    .touchpointAction("start_dispute", description: "outer") { }
            }
        )
        #expect(set.names == ["open_account", "start_dispute"])
        #expect(set["start_dispute"]?.description == "inner")
    }
}
#endif
