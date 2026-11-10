import Foundation
import Testing
@testable import TouchpointCore

/// LN-1 (web's languages) and OP-7 (host string overrides). Serialised because the language
/// override and the override map are process-wide; each test that touches them resets in `defer`.
@Suite("Localization", .serialized)
struct LocalizationTests {

    // MARK: language resolution — web's rules (useCopy.ts defaultCopy)

    @Test("Base languages resolve to their catalog code")
    func baseLanguages() {
        #expect(touchpointTranslationCode(for: "de-DE") == "de")
        #expect(touchpointTranslationCode(for: "es") == "es")
        #expect(touchpointTranslationCode(for: "it-IT") == "it")
        #expect(touchpointTranslationCode(for: "ja-JP") == "ja")
        #expect(touchpointTranslationCode(for: "ko") == "ko")
        #expect(touchpointTranslationCode(for: "pt-BR") == "pt-BR")
        #expect(touchpointTranslationCode(for: "pt-PT") == "pt-BR") // web keys all pt to its one pt
    }

    @Test("French: only fr-CA is Canadian; every other fr is France French")
    func french() {
        #expect(touchpointTranslationCode(for: "fr-CA") == "fr-CA")
        #expect(touchpointTranslationCode(for: "fr_CA") == "fr-CA") // underscore form normalises
        #expect(touchpointTranslationCode(for: "fr") == "fr")
        #expect(touchpointTranslationCode(for: "fr-FR") == "fr")
    }

    @Test("Chinese follows web exactly: zh-TW/zh-Hant Traditional, every other zh Simplified")
    func chinese() {
        #expect(touchpointTranslationCode(for: "zh-TW") == "zh-Hant")
        #expect(touchpointTranslationCode(for: "zh-Hant") == "zh-Hant")
        #expect(touchpointTranslationCode(for: "zh-Hant-HK") == "zh-Hant")
        #expect(touchpointTranslationCode(for: "zh-CN") == "zh-Hans")
        #expect(touchpointTranslationCode(for: "zh-Hans") == "zh-Hans")
        #expect(touchpointTranslationCode(for: "zh") == "zh-Hans")
        // Deviation (web wins): zh-HK is Simplified under web's rules, not Traditional.
        #expect(touchpointTranslationCode(for: "zh-HK") == "zh-Hans")
    }

    @Test("Indonesian resolves from both the modern and legacy codes")
    func indonesian() {
        #expect(touchpointTranslationCode(for: "id") == "id")
        #expect(touchpointTranslationCode(for: "id-ID") == "id")
        #expect(touchpointTranslationCode(for: "in") == "id")
    }

    @Test("English and unsupported languages fall back (nil)")
    func fallback() {
        #expect(touchpointTranslationCode(for: "en") == nil)
        #expect(touchpointTranslationCode(for: "en-US") == nil)
        #expect(touchpointTranslationCode(for: "ru") == nil)
        #expect(touchpointTranslationCode(for: "") == nil)
    }

    // MARK: the bundled translations actually resolve

    /// Resolves a key straight from an `.lproj` sub-bundle, the way `TouchpointStrings.key` does,
    /// without touching the process-wide language — proof the catalog shipped the translation.
    private func bundled(_ key: String, _ code: String) -> String? {
        guard let bundle = LocalizationStore.shared.localizedBundle(for: code) else { return nil }
        let sentinel = "\u{0}missing\u{0}"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }

    @Test("A known string resolves in ja, zh-Hant and fr-CA")
    func knownStringsResolve() {
        #expect(bundled("touchpoint.settings.endConfirmTitle", "ja") == "よろしいですか？")
        #expect(bundled("touchpoint.settings.endConfirmTitle", "zh-Hant") == "確定嗎？")
        // fr-CA drops the space before "?" that France French keeps — proof the region won, not fr.
        #expect(bundled("touchpoint.settings.endConfirmTitle", "fr-CA") == "Êtes-vous sûr?")
        #expect(bundled("touchpoint.settings.endConfirmTitle", "fr") == "Êtes-vous sûr ?")
        // The count template carries the %d specifier through translation.
        #expect(bundled("touchpoint.announcement.choice", "ja") == "選択肢が%d件あります")
    }

    @Test("A key with no translation is absent from a localised bundle (English fallback path)")
    func untranslatedKeyAbsent() {
        // composer.send is intentionally en-only (iOS says "Send", web "Send message").
        #expect(bundled("touchpoint.composer.send", "ja") == nil)
    }

    // MARK: TouchpointCopy.languageCode — host forces the language

    @Test("Forcing languageCode switches the rendered string, and clearing restores English")
    func forceLanguage() {
        #expect(TouchpointCopy.languageCode == nil)
        defer { TouchpointCopy.languageCode = nil }

        TouchpointCopy.languageCode = "ja"
        #expect(TouchpointStrings.settingsEndConfirmTitle == "よろしいですか？")

        TouchpointCopy.languageCode = "zh-Hant-HK"
        #expect(TouchpointStrings.settingsEndConfirmTitle == "確定嗎？")

        TouchpointCopy.languageCode = "en"
        #expect(TouchpointStrings.settingsEndConfirmTitle == "Are you sure?")
    }

    @Test("An untranslated key stays English even under a forced language")
    func forcedLanguageFallsBackPerKey() {
        defer { TouchpointCopy.languageCode = nil }
        TouchpointCopy.languageCode = "ja"
        // Translated and untranslated keys coexist: one localises, one stays en.
        #expect(TouchpointStrings.settingsEndConfirmTitle == "よろしいですか？")
        #expect(TouchpointStrings.sendButtonLabel == "Send")
    }

    // MARK: TouchpointCopy.overrides — OP-7

    @Test("A host override wins over the bundled translation")
    func overrideWins() {
        defer {
            TouchpointCopy.clearOverrides()
            TouchpointCopy.languageCode = nil
        }
        TouchpointCopy.languageCode = "ja"
        TouchpointCopy.setOverride("touchpoint.settings.endConfirmTitle", "Really?")
        #expect(TouchpointStrings.settingsEndConfirmTitle == "Really?")

        // Clearing restores the translation.
        TouchpointCopy.clearOverrides()
        #expect(TouchpointStrings.settingsEndConfirmTitle == "よろしいですか？")
    }

    @Test("Overrides can replace an otherwise en-only string")
    func overrideEnOnlyKey() {
        defer { TouchpointCopy.clearOverrides() }
        TouchpointCopy.overrides = ["touchpoint.composer.send": "Zenden"]
        #expect(TouchpointStrings.sendButtonLabel == "Zenden")
    }
}
