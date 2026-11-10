import Foundation
import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointChat

/// Web 1.0.6's hidden and added elements (f3120c4, 8cebb4d), the end confirmation's copy, and the
/// header notice — options a host's web configuration sets. The overlay itself needs a running
/// app's UI tests.
@Suite("Header elements and the end confirmation")
@MainActor
struct HeaderElementsTests {
    @Test("The added close follows the view's own close, and only exists with one (web: `collapse != null`)")
    func addedCloseOrder() {
        #expect(ChatHeaderBar.controls(hasRestart: false, hasSettings: true, hasClose: true, hasCloseConversation: true)
                == [.settings, .close, .closeConversation])
        #expect(ChatHeaderBar.controls(hasRestart: false, hasSettings: true, hasClose: false, hasCloseConversation: true)
                == [.settings])
        // With a brand, all of them trail it.
        let placed = ChatHeaderBar.placement([.settings, .close, .closeConversation], hasBrand: true)
        #expect(placed.leading.isEmpty)
        #expect(placed.trailing == [.settings, .close, .closeConversation])
    }

    @Test("Beside the added close the view's own close is a minimise, as web's collapse is in text mode")
    func collapseGlyph() {
        #expect(ChatHeaderBar.collapseMinimises(closeStyle: .close, hasCloseConversation: true))
        #expect(ChatHeaderBar.collapseMinimises(closeStyle: nil, hasCloseConversation: true))
        #expect(!ChatHeaderBar.collapseMinimises(closeStyle: .close, hasCloseConversation: false))
        #expect(ChatHeaderBar.collapseMinimises(closeStyle: .minimise, hasCloseConversation: false))
    }

    @Test("With the header's restart hidden, restart alone earns the settings panel: nowhere else is left")
    func hiddenRestartKeepsSettings() {
        let restartOnly = TouchpointChatActions(onRestart: {})
        #expect(!restartOnly.hasBuiltInSettings(headerRestartHidden: false))
        #expect(restartOnly.hasBuiltInSettings(headerRestartHidden: true))
        #expect(!TouchpointChatActions().hasBuiltInSettings(headerRestartHidden: true))
        #expect(!TouchpointChatActions(onRestart: {}, onSettings: {}).hasBuiltInSettings(headerRestartHidden: true))
    }

    @Test("Hiding the welcome logo is the same as `welcomeScreenLogo: false` (web keeps both spellings)")
    func hiddenWelcomeLogo() {
        #expect(!ChatOptions.showsWelcomeLogo(hasBrandIcon: true,
                                              options: TouchpointChatOptions(hiddenElements: [.welcomeScreenLogo])))
        #expect(ChatOptions.showsWelcomeLogo(hasBrandIcon: true,
                                             options: TouchpointChatOptions(hiddenElements: [.headerRestart])))
    }

    @Test("The elements carry web's identifiers")
    func webIdentifiers() {
        #expect(TouchpointHiddenElement.headerRestart.rawValue == "header.restart")
        #expect(TouchpointHiddenElement.headerSettings.rawValue == "header.settings")
        #expect(TouchpointHiddenElement.welcomeScreenLogo.rawValue == "welcomescreen.logo")
        #expect(TouchpointAddedElement.headerClose.rawValue == "header.close")
    }

    @Test("The confirmation takes the host's words where set and the SDK's elsewhere")
    func confirmCopy() {
        let base = ChatOptions.endConfirmCopy(TouchpointChatCopy())
        #expect(base.title == TouchpointStrings.settingsEndConfirmTitle)
        #expect(base.body == TouchpointStrings.settingsEndConfirmBody)
        #expect(base.confirm == TouchpointStrings.settingsEndLabel)
        #expect(base.cancel == TouchpointStrings.settingsCancelLabel)
        let host = ChatOptions.endConfirmCopy(TouchpointChatCopy(endConversationConfirm: .init(
            body: "Save a copy first.", confirm: "End it")))
        #expect(host.title == TouchpointStrings.settingsEndConfirmTitle)
        #expect(host.body == "Save a copy first.")
        #expect(host.confirm == "End it")
        #expect(host.cancel == TouchpointStrings.settingsCancelLabel)
    }

    @Test("Defaults change nothing: no hidden or added elements, no notice, the SDK's copy")
    func defaults() {
        let o = TouchpointChatOptions.default
        #expect(o.hiddenElements.isEmpty)
        #expect(o.addedElements.isEmpty)
        #expect(o.copy == TouchpointChatCopy())
        #expect(ChatHeader().notice == nil)
    }
}
