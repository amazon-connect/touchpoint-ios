import Foundation

/// The Live Sync channel a conversation targets, derived from a `Locale`.
///
/// The backend's channel key is `connect-<languageTag>` and must match the deployment exactly:
/// `en` and `en-US` are **different channels**, and a mismatch surfaces only as a rejected
/// context request. So the mapping is explicit, host-overridable, and never defaults silently.
///
/// The tag is composed from the locale's language, script and region subtags — canonicalised to
/// BCP 47 case (`zh-Hant-TW`) — rather than echoing `Locale.identifier`, so Unicode extension
/// keywords (`-u-ca-gregory`, `@currency=USD`) and variant subtags never leak into the channel.
public struct LiveSyncChannel: Hashable, Sendable {
    /// Canonical BCP 47 tag as the deployment expects it, e.g. `en-US`, `fr-CA`, `zh-Hant-TW`.
    public let languageTag: String

    /// Wire-level channel key: `connect-<languageTag>`.
    public var key: String { "connect-\(languageTag)" }

    public enum MappingError: Error, Equatable, Sendable {
        /// The locale carries no usable language subtag (empty, or `und`), so no channel can be chosen.
        case undeterminedLanguage
        /// A host override mapped the locale to an empty or whitespace-only tag.
        case invalidOverride
    }

    /// - Parameters:
    ///   - locale: The locale to map.
    ///   - overrides: Host-supplied map from a **canonical** tag (as this type would derive it) to
    ///     the deployment's channel language. Lets a host route `en-GB` devices to an `en-US`
    ///     deployment without touching the device locale.
    public init(locale: Locale, overrides: [String: String] = [:]) throws {
        let derived = try Self.canonicalTag(for: locale)
        if let override = overrides[derived] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MappingError.invalidOverride }
            languageTag = trimmed
        } else {
            languageTag = derived
        }
    }

    private static func canonicalTag(for locale: Locale) throws -> String {
        // `Locale.Language` infers missing subtags (every Latin-script locale reports `Latn`), so
        // parse the identifier into *explicit* components instead; the deployment's channel set is
        // keyed on what the host wrote, not on likely-subtag expansion.
        let components = Locale.Language.Components(identifier: locale.identifier)
        guard
            let language = components.languageCode?.identifier.lowercased(),
            !language.isEmpty, language != "und"
        else { throw MappingError.undeterminedLanguage }

        var parts = [language]
        if let script = components.script?.identifier, !script.isEmpty {
            parts.append(script.prefix(1).uppercased() + script.dropFirst().lowercased())
        }
        if let region = components.region?.identifier, !region.isEmpty {
            parts.append(region.uppercased())
        }
        return parts.joined(separator: "-")
    }
}
