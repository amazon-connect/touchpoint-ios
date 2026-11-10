import Testing
import TouchpointCore
@testable import TouchpointChat

@Suite("TouchpointChat smoke")
struct TouchpointChatSmokeTests {
    @Test("Module links against Core and reports the shared version")
    func version() {
        #expect(TouchpointChat.version == Touchpoint.version)
    }
}
