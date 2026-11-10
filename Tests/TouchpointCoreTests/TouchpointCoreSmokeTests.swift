import Testing
@testable import TouchpointCore

@Suite("TouchpointCore smoke")
struct TouchpointCoreSmokeTests {
    @Test("Module exposes a semantic version")
    func version() {
        #expect(Touchpoint.version == "0.1.0")
    }

    @Test("String catalog is bundled and resolves a key")
    func stringCatalogResolves() {
        // The catalog's `en` source value for this key; if the resource were missing,
        // `Bundle.module` would trap at access time, which is what this test guards against.
        #expect(TouchpointStrings.placeholder == "Touchpoint")
    }
}
