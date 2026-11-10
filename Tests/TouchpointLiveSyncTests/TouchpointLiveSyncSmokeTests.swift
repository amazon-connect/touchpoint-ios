import Testing
import TouchpointCore
@testable import TouchpointLiveSync

@Suite("TouchpointLiveSync smoke")
struct TouchpointLiveSyncSmokeTests {
    @Test("Module links against Core and reports the shared version")
    func version() {
        #expect(TouchpointLiveSync.version == Touchpoint.version)
    }
}
