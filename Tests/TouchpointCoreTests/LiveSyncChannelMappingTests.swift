import Foundation
import Testing
@testable import TouchpointCore

@Suite("Locale → Live Sync channel mapping")
struct LiveSyncChannelMappingTests {
    @Test("en-US maps to connect-en-US")
    func fullTag() throws {
        let channel = try LiveSyncChannel(locale: Locale(identifier: "en-US"))
        #expect(channel.languageTag == "en-US")
        #expect(channel.key == "connect-en-US")
    }

    @Test("en and en-US are different channels")
    func languageOnlyIsDistinct() throws {
        let en = try LiveSyncChannel(locale: Locale(identifier: "en"))
        let enUS = try LiveSyncChannel(locale: Locale(identifier: "en-US"))
        #expect(en.languageTag == "en")
        #expect(en.key == "connect-en")
        #expect(en != enUS)
    }

    @Test("POSIX underscore identifiers are normalised to BCP 47 hyphens")
    func posixUnderscore() throws {
        #expect(try LiveSyncChannel(locale: Locale(identifier: "en_US")).languageTag == "en-US")
    }

    @Test("Region is preserved")
    func region() throws {
        #expect(try LiveSyncChannel(locale: Locale(identifier: "fr-CA")).languageTag == "fr-CA")
    }

    @Test("Script subtag is preserved")
    func script() throws {
        #expect(try LiveSyncChannel(locale: Locale(identifier: "zh-Hant-TW")).languageTag == "zh-Hant-TW")
    }

    @Test("Unicode extension keywords do not leak into the channel")
    func extensionKeywordsStripped() throws {
        #expect(try LiveSyncChannel(locale: Locale(identifier: "en-US-u-ca-gregory")).languageTag == "en-US")
        #expect(try LiveSyncChannel(locale: Locale(identifier: "en_US@currency=USD")).languageTag == "en-US")
    }

    @Test("Case is canonicalised: lowercase language, titlecase script, uppercase region")
    func caseCanonicalised() throws {
        #expect(try LiveSyncChannel(locale: Locale(identifier: "EN-us")).languageTag == "en-US")
        #expect(try LiveSyncChannel(locale: Locale(identifier: "zh-hant-tw")).languageTag == "zh-Hant-TW")
    }

    @Test("Variant subtags are dropped — the deployment channel set never carries them")
    func variantDropped() throws {
        #expect(try LiveSyncChannel(locale: Locale(identifier: "de-DE-1996")).languageTag == "de-DE")
    }

    @Test("Host override wins over the derived tag")
    func hostOverride() throws {
        let channel = try LiveSyncChannel(
            locale: Locale(identifier: "en-GB"),
            overrides: ["en-GB": "en-US"]
        )
        #expect(channel.languageTag == "en-US")
        #expect(channel.key == "connect-en-US")
    }

    @Test("Overrides are matched against the canonical tag, not the raw identifier")
    func overrideMatchesCanonicalTag() throws {
        let channel = try LiveSyncChannel(
            locale: Locale(identifier: "en_gb@calendar=gregorian"),
            overrides: ["en-GB": "en-US"]
        )
        #expect(channel.languageTag == "en-US")
    }

    @Test("An empty locale is rejected rather than silently defaulted")
    func emptyLocaleThrows() {
        #expect(throws: LiveSyncChannel.MappingError.undeterminedLanguage) {
            try LiveSyncChannel(locale: Locale(identifier: ""))
        }
    }

    @Test("The undetermined language `und` is rejected")
    func undThrows() {
        #expect(throws: LiveSyncChannel.MappingError.undeterminedLanguage) {
            try LiveSyncChannel(locale: Locale(identifier: "und"))
        }
    }

    @Test("Override to an empty string is rejected")
    func emptyOverrideThrows() {
        #expect(throws: LiveSyncChannel.MappingError.invalidOverride) {
            try LiveSyncChannel(locale: Locale(identifier: "en-US"), overrides: ["en-US": ""])
        }
    }
}
