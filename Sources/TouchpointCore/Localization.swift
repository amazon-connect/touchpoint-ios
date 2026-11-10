import Foundation

/// Host-facing localisation configuration — Touchpoint web's `languageCode` and `copy`
/// (`TouchpointConfiguration`), in the SDK's terms (gaps LN-1, OP-7).
///
/// - ``languageCode`` forces the UI language the way web's `languageCode` does; left unset, the SDK
///   follows the device language, resolved with web's own rules (see ``TouchpointStrings``).
/// - ``overrides`` replaces individual strings the way web's `copy` does, and wins over every
///   translation. Keys are the catalog identifiers (`"touchpoint.*"`); whatever string the host
///   supplies is shown verbatim, in whatever language the host wrote it.
///
/// **Deviation (Android):** Android has no programmatic string-override call — a host redefines a
/// `touchpoint_*` string *resource* and Android's resource overlay wins. iOS has no equivalent
/// overlay for a Swift package's String Catalog consumed by a host, so the same capability is a
/// programmatic map here. The capability (override any SDK string) is identical.
///
/// Thread-safe: values are read while rendering (main actor) and may be set from anywhere.
public enum TouchpointCopy {
    /// BCP-47 language code that overrides the device language for built-in UI copy (web's
    /// `TouchpointConfiguration.languageCode`). `nil` (the default) follows the device.
    public static var languageCode: String? {
        get { LocalizationStore.shared.languageCode }
        set { LocalizationStore.shared.languageCode = newValue }
    }

    /// Host overrides for individual SDK strings (web's `TouchpointConfiguration.copy`), keyed by
    /// catalog identifier, e.g. `["touchpoint.composer.send": "Send it"]`. An entry wins over the
    /// bundled translation for every language. Replacing the map replaces all overrides.
    public static var overrides: [String: String] {
        get { LocalizationStore.shared.overrides }
        set { LocalizationStore.shared.overrides = newValue }
    }

    /// Overrides a single SDK string, keyed by its catalog identifier. Convenience over mutating
    /// ``overrides`` wholesale.
    public static func setOverride(_ key: String, _ value: String) {
        LocalizationStore.shared.setOverride(key, value)
    }

    /// Removes every host override, restoring the bundled translations.
    public static func clearOverrides() {
        LocalizationStore.shared.overrides = [:]
    }
}

/// Maps a BCP-47 language code to one of the catalog's bundled translation codes (an `.lproj`
/// name), following the exact rules Touchpoint web uses in `useCopy.ts` `defaultCopy`. Returns
/// `nil` for English and for anything web would fall back to English on.
///
/// **Deviation (web wins):** the brief and the Android port send `zh-HK` to Traditional Chinese.
/// Web — the behaviour bar — does not: `defaultCopy` sends only `zh-TW` and `zh-Hant*` to
/// Traditional and every other `zh*` (Hong Kong included) to Simplified. This follows web.
func touchpointTranslationCode(for languageCode: String) -> String? {
    // Web: `(languageCode || "en").toLowerCase().replace(/_/g, "-")`.
    let code = languageCode.lowercased().replacingOccurrences(of: "_", with: "-")
    if code == "zh-tw" || code.hasPrefix("zh-hant") { return "zh-Hant" }
    if code.hasPrefix("zh") { return "zh-Hans" }
    if code == "fr-ca" { return "fr-CA" }
    // Web: `BY_LANGUAGE[code.split("-")[0]] ?? en`.
    let base = code.split(separator: "-").first.map(String.init) ?? code
    switch base {
    case "de", "es", "fr", "it", "ja", "ko":
        return base
    case "id", "in":
        // Indonesian. `in` is the deprecated ISO code some platforms still report; both are `id`.
        return "id"
    case "pt":
        // Web ships Brazilian Portuguese as its only `pt`; the catalog carries it as `pt-BR`.
        return "pt-BR"
    default:
        return nil
    }
}

/// Process-wide store for ``TouchpointCopy``'s language override, string overrides, and a cache of
/// the per-language resource bundles. `@unchecked Sendable` because every access is serialised by
/// `lock`; nothing mutable escapes it.
final class LocalizationStore: @unchecked Sendable {
    static let shared = LocalizationStore()

    private let lock = NSLock()
    private var _languageCode: String?
    private var _overrides: [String: String] = [:]
    private var _bundleCache: [String: Bundle] = [:]
    /// `.lproj` names that have been looked up and found absent, so a missing language is not
    /// probed on disk on every string read.
    private var _absent: Set<String> = []

    var languageCode: String? {
        get { lock.withLock { _languageCode } }
        set { lock.withLock { _languageCode = newValue } }
    }

    var overrides: [String: String] {
        get { lock.withLock { _overrides } }
        set { lock.withLock { _overrides = newValue } }
    }

    func setOverride(_ key: String, _ value: String) {
        lock.withLock { _overrides[key] = value }
    }

    func override(for key: String) -> String? {
        lock.withLock { _overrides[key] }
    }

    /// The `.lproj` sub-bundle for a catalog language code, or `nil` if the SDK ships no such
    /// localisation. Cached; the lookup touches the filesystem at most once per code.
    func localizedBundle(for code: String) -> Bundle? {
        lock.withLock {
            if let cached = _bundleCache[code] { return cached }
            if _absent.contains(code) { return nil }
            guard let path = Bundle.module.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                _absent.insert(code)
                return nil
            }
            _bundleCache[code] = bundle
            return bundle
        }
    }
}
