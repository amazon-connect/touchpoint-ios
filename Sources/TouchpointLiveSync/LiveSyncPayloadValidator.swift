import Foundation

/// Checks an action payload against the JSON Schema the app advertised, on the device, before any
/// handler sees it. The Live Sync backend does not validate against the
/// advertised schema — it rebuilds a lossy copy of it — so this is the only check that holds.
///
/// A strict subset of JSON Schema, chosen to cover tool-parameter schemas, and **fail-closed**:
/// a keyword outside the subset makes the schema unsupported, and every payload against it is
/// rejected. A standards validator does the opposite (an unknown keyword is an annotation and is
/// ignored), which is the wrong default for a security control.
///
/// Supported: `type` (a name or an array of names), `enum`, `const`, `properties`, `required`,
/// `additionalProperties` (bool or schema), `items` (one schema), `minItems`, `maxItems`,
/// `minLength`, `maxLength` (Unicode scalars), `minimum`, `maximum`, `exclusiveMinimum`,
/// `exclusiveMaximum` (numeric forms), and `format: "date"` (`YYYY-MM-DD`, a real calendar date).
/// Ignored as annotations: `title`, `description`, `$schema`, `$id`, `$comment`, `examples`,
/// `default`, `deprecated`, `readOnly`, `writeOnly`. Everything else — `pattern`, `multipleOf`,
/// other formats, `oneOf`/`anyOf`/`allOf`/`not`, `$ref`, conditionals, tuple `items` — is
/// unsupported.
///
/// A violation names the keyword and a JSON Pointer into the payload, never a value or a key the
/// payload chose: an unexpected property is reported at its parent.
enum LiveSyncPayloadValidator {
    struct Violation: Equatable, Sendable, CustomStringConvertible {
        /// The schema keyword that failed, or the unsupported keyword.
        let keyword: String
        /// RFC 6901 pointer into the payload; `""` is the root.
        let pointer: String
        /// `true` when the schema itself is outside the supported subset.
        let unsupported: Bool

        var description: String {
            let at = pointer.isEmpty ? "/" : pointer
            return unsupported ? "unsupported schema keyword \(keyword) at \(at)" : "\(keyword) at \(at)"
        }
    }

    static let annotations: Set<String> = [
        "title", "description", "$schema", "$id", "$comment", "examples", "default", "deprecated", "readOnly", "writeOnly",
    ]
    static let assertions: Set<String> = [
        "type", "enum", "const", "properties", "required", "additionalProperties", "items", "minItems", "maxItems",
        "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "format",
    ]
    static let formats: Set<String> = ["date"]
    /// Assertions that constrain only one kind of value, so require a `type` alongside them.
    static let typeSpecific = ["properties", "required", "additionalProperties", "items", "minItems", "maxItems",
                               "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "format"]

    /// The first violation, or `nil` when the payload conforms.
    static func validate(_ value: JSONValue, against schema: JSONValue) -> Violation? {
        // The whole schema is vetted once, up front; the instance walk then trusts it.
        if let problem = schemaProblem(schema, at: "") { return problem }
        return check(value, schema, pointer: "")
    }

    /// The first unsupported keyword in `schema`, wherever it is nested, or `nil` when the whole
    /// schema is inside the subset — so an app hears at advertise time that an action can never run.
    static func unsupportedKeyword(in schema: JSONValue) -> Violation? {
        schemaProblem(schema, at: "")
    }

    /// Top-level property names the Live Sync backend rewrites: when an object payload carries a
    /// truthy `items` or `value`, the engine sends only that member's value as the payload, which
    /// no longer matches the schema the app declared — so the device would reject it.
    static let backendUnwrappedPropertyNames = ["items", "value"]

    static func backendUnwrappedProperty(in schema: JSONValue) -> String? {
        guard case .object(let s) = schema, case .object(let properties) = s["properties"] else { return nil }
        return backendUnwrappedPropertyNames.first { properties[$0] != nil }
    }

    /// Where the Live Sync engine's own schema conversion will not produce what the schema says: it
    /// turns a node with no `type`, a `type` array and `"null"` into a string. The device validates
    /// against the schema as written: `admitsString` says whether the string the engine sends can
    /// still pass there, or the action's invocations will be rejected.
    struct EngineRewrite: Equatable {
        let description: String
        let admitsString: Bool
    }

    static func engineRewrite(in schema: JSONValue, at path: String = "") -> EngineRewrite? {
        guard case .object(let s) = schema else { return nil }
        let at = path.isEmpty ? "/" : path
        func onlyStrings(_ values: [JSONValue]) -> Bool { values.allSatisfy { if case .string = $0 { true } else { false } } }
        switch s["type"] {
        case nil:
            // An enum or const of strings survives the engine's string conversion; anything else
            // arrives as a string it no longer matches.
            var values: [JSONValue] = []
            if case .array(let options) = s["enum"] { values += options }
            if let constant = s["const"] { values.append(constant) }
            if !values.isEmpty && onlyStrings(values) { break }
            return EngineRewrite(description: "a node with no type at \(at)", admitsString: values.isEmpty)
        case .array(let names)?:
            return EngineRewrite(description: "a type array at \(at)", admitsString: names.contains(.string("string")))
        case .string("null")?:
            return EngineRewrite(description: "type null at \(at)", admitsString: false)
        default: break
        }
        if case .object(let properties) = s["properties"] {
            for name in properties.keys.sorted() {
                if let found = engineRewrite(in: properties[name] ?? .null, at: path + "/" + escape(name)) { return found }
            }
        }
        if let items = s["items"], let found = engineRewrite(in: items, at: path + "/items") { return found }
        if case .object = s["additionalProperties"], let extra = s["additionalProperties"],
           let found = engineRewrite(in: extra, at: path) { return found }
        return nil
    }

    // MARK: - Schema walk

    private static func schemaProblem(_ schema: JSONValue, at path: String) -> Violation? {
        // `true` / `false` are valid boolean schemas only as `additionalProperties`, handled there.
        guard case .object(let keywords) = schema else { return Violation(keyword: "schema", pointer: path, unsupported: true) }
        for key in keywords.keys.sorted() where !annotations.contains(key) && !assertions.contains(key) {
            return Violation(keyword: key, pointer: path, unsupported: true)
        }
        if let format = keywords["format"] {
            guard case .string(let name) = format, formats.contains(name) else {
                return Violation(keyword: "format", pointer: path, unsupported: true)
            }
        }
        for key in ["exclusiveMinimum", "exclusiveMaximum", "minimum", "maximum"] {
            if let bound = keywords[key], number(bound) == nil { return Violation(keyword: key, pointer: path, unsupported: true) }
        }
        for key in ["minItems", "maxItems", "minLength", "maxLength"] {
            if let bound = keywords[key], count(bound) == nil { return Violation(keyword: key, pointer: path, unsupported: true) }
        }
        if let type = keywords["type"], typeNames(type) == nil { return Violation(keyword: "type", pointer: path, unsupported: true) }
        // Without a `type`, JSON Schema applies these only to values of their own kind, so a string
        // would pass a schema that looks like an object's: name the type for them to bind.
        if keywords["type"] == nil, let loose = typeSpecific.first(where: { keywords[$0] != nil }) {
            return Violation(keyword: "\(loose) without type", pointer: path, unsupported: true)
        }
        if let values = keywords["enum"] {
            guard case .array = values else { return Violation(keyword: "enum", pointer: path, unsupported: true) }
        }
        if let required = keywords["required"] {
            guard case .array(let names) = required, names.allSatisfy({ if case .string = $0 { true } else { false } }) else {
                return Violation(keyword: "required", pointer: path, unsupported: true)
            }
        }
        if let properties = keywords["properties"] {
            guard case .object(let children) = properties else { return Violation(keyword: "properties", pointer: path, unsupported: true) }
            for name in children.keys.sorted() {
                if let problem = schemaProblem(children[name] ?? .null, at: path + "/" + escape(name)) { return problem }
            }
        }
        if let extra = keywords["additionalProperties"] {
            if case .bool = extra {} else if let problem = schemaProblem(extra, at: path) { return problem }
        }
        if let items = keywords["items"] {
            // A tuple (`items: [ … ]`) is draft-04's positional form: not in the subset.
            if let problem = schemaProblem(items, at: path + "/items") { return problem }
        }
        return nil
    }

    // MARK: - Instance walk

    private static func check(_ value: JSONValue, _ schema: JSONValue, pointer: String) -> Violation? {
        guard case .object(let s) = schema else { return nil }
        func fail(_ keyword: String) -> Violation { Violation(keyword: keyword, pointer: pointer, unsupported: false) }

        if let type = s["type"], let names = typeNames(type), !names.contains(where: { matches(value, type: $0) }) {
            return fail("type")
        }
        if case .array(let options) = s["enum"], !options.contains(where: { same(value, $0) }) { return fail("enum") }
        if let constant = s["const"], !same(value, constant) { return fail("const") }

        switch value {
        case .string(let text):
            let length = text.unicodeScalars.count
            if let min = s["minLength"].flatMap(count), length < min { return fail("minLength") }
            if let max = s["maxLength"].flatMap(count), length > max { return fail("maxLength") }
            if case .string("date") = s["format"], !isCalendarDate(text) { return fail("format") }
        case .int, .double:
            guard number(value) != nil else { return fail("type") }
            func order(_ bound: String) -> Int? { s[bound].flatMap { compare(value, $0) } }
            if let o = order("minimum"), o < 0 { return fail("minimum") }
            if let o = order("maximum"), o > 0 { return fail("maximum") }
            if let o = order("exclusiveMinimum"), o <= 0 { return fail("exclusiveMinimum") }
            if let o = order("exclusiveMaximum"), o >= 0 { return fail("exclusiveMaximum") }
        case .array(let elements):
            if let min = s["minItems"].flatMap(count), elements.count < min { return fail("minItems") }
            if let max = s["maxItems"].flatMap(count), elements.count > max { return fail("maxItems") }
            if let items = s["items"] {
                for (index, element) in elements.enumerated() {
                    if let v = check(element, items, pointer: pointer + "/\(index)") { return v }
                }
            }
        case .object(let members):
            let properties: [String: JSONValue]
            if case .object(let p) = s["properties"] { properties = p } else { properties = [:] }
            // A `null` for a property whose schema does not admit null counts as not sent — what an
            // optional Decodable property makes of it. One that admits null is checked as a value.
            func notSent(_ name: String) -> Bool {
                guard let member = members[name] else { return true }
                return member == .null && !admitsNull(properties[name])
            }
            if case .array(let names) = s["required"] {
                for case .string(let name) in names where notSent(name) { return fail("required") }
            }
            for name in members.keys.sorted() {
                let member = members[name] ?? .null
                if let child = properties[name] {
                    if notSent(name) { continue }   // optional and absent; `required` handled above
                    if let v = check(member, child, pointer: pointer + "/" + escape(name)) { return v }
                } else if let extra = s["additionalProperties"] {
                    switch extra {
                    case .bool(false): return fail("additionalProperties")   // the parent, never the key
                    case .bool(true): break
                    default: if let v = check(member, extra, pointer: pointer) { return v }
                    }
                }
            }
        case .bool, .null:
            break
        }
        return nil
    }

    // MARK: - Helpers

    private static let typeNameSet: Set<String> = ["string", "number", "integer", "boolean", "object", "array", "null"]

    private static func admitsNull(_ schema: JSONValue?) -> Bool {
        guard case .object(let s)? = schema, let type = s["type"], let names = typeNames(type) else { return false }
        return names.contains("null")
    }

    private static func typeNames(_ type: JSONValue) -> [String]? {
        switch type {
        case .string(let name): return typeNameSet.contains(name) ? [name] : nil
        case .array(let names):
            var result: [String] = []
            for case .string(let name) in names where typeNameSet.contains(name) { result.append(name) }
            return result.count == names.count && !result.isEmpty ? result : nil
        default: return nil
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null): true
        case ("number", .int), ("number", .double): number(value) != nil
        case ("integer", .int): true
        // Integral and finite — not `intValue`, which rounds 3.5 to 4.
        case ("integer", .double(let d)): d.isFinite && d == d.rounded(.towardZero)
        default: false
        }
    }

    /// A finite number, whichever case carries it.
    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let i): Double(i)
        case .double(let d): d.isFinite ? d : nil
        default: nil
        }
    }

    /// A non-negative integral bound (`minLength` and the like).
    private static func count(_ value: JSONValue) -> Int? {
        switch value {
        case .int(let i) where i >= 0: i
        case .double(let d) where d >= 0: Int(exactly: d)
        default: nil
        }
    }

    /// -1, 0 or 1 for two numbers, exactly between integers (a `Double` loses precision past 2^53);
    /// through `Double` only when one side is not an integer. `nil` when either is not a number.
    private static func compare(_ a: JSONValue, _ b: JSONValue) -> Int? {
        if case .int(let x) = a, case .int(let y) = b { return x < y ? -1 : (x == y ? 0 : 1) }
        guard let x = number(a), let y = number(b) else { return nil }
        return x < y ? -1 : (x == y ? 0 : 1)
    }

    /// JSON equality, numbers by value: a schema literal `1.0` (`.double`) equals a wire `1` (`.int`).
    private static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double):
            return compare(a, b) == 0
        case (.array(let x), .array(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { key, value in y[key].map { same(value, $0) } ?? false }
        default:
            return a == b
        }
    }

    /// RFC 3339 `full-date`: four, two and two ASCII digits, and a day that exists.
    static func isCalendarDate(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else { return false }
        func digits(_ range: Range<Int>) -> Int? {
            var n = 0
            for b in bytes[range] {
                guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
                n = n * 10 + Int(b - UInt8(ascii: "0"))
            }
            return n
        }
        guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              (1...12).contains(month), day >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return day <= days
    }

    /// RFC 6901 escaping for a pointer segment.
    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}
