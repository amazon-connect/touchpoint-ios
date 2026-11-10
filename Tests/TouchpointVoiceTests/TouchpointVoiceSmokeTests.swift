import Testing
import TouchpointCore
@testable import TouchpointVoice

@Suite("TouchpointVoice smoke")
struct TouchpointVoiceSmokeTests {
    @Test("Module links against Core and reports the shared version")
    func version() {
        #expect(TouchpointVoice.version == Touchpoint.version)
    }
}
