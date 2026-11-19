import Foundation
import Testing
import TouchpointChat
@testable import AcmeBank

/// The demo's own policy over `TouchpointSession.onIncomingMessages`: the SDK reports every reply,
/// and this app decides to notify unless the conversation is on screen in the foreground.
@Suite("Acme Bank notification policy")
@MainActor
struct NotificationPolicyTests {
    @Test("Notify unless the app is in the foreground with the conversation showing")
    func shouldNotify() {
        #expect(!SupportCoordinator.shouldNotify(appIsActive: true, conversationOnScreen: true))
        #expect(SupportCoordinator.shouldNotify(appIsActive: true, conversationOnScreen: false))
        #expect(SupportCoordinator.shouldNotify(appIsActive: false, conversationOnScreen: true))
        #expect(SupportCoordinator.shouldNotify(appIsActive: false, conversationOnScreen: false))
    }

    @Test("The conversation is on screen only with the dock open, not mini, and no full-screen call")
    func conversationOnScreen() {
        let model = AppModel()
        #expect(!model.conversationOnScreen)
        model.supportExpanded = true
        #expect(model.conversationOnScreen)
        model.chatWindowPick = .mini
        #expect(!model.conversationOnScreen)
        model.chatWindowPick = .half
        model.voiceFullScreen = true
        #expect(!model.conversationOnScreen)
    }
}
