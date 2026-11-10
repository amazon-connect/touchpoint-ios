import Foundation
import Testing

@testable import TouchpointLiveSync

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Literals build the expected tree")
    func literals() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "quantity": ["type": "number", "minimum": 1],
                "gift": ["type": "boolean"],
            ],
            "required": ["quantity"],
        ]

        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["properties"]?["quantity"]?["minimum"]?.intValue == 1)
        #expect(schema["required"]?[0]?.stringValue == "quantity")
    }

    @Test("Integers survive a round trip without becoming floats")
    func integersKeepTheirShape() throws {
        let value: JSONValue = ["quantity": 2, "price": 3.5, "gift": true, "note": nil]
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("\"quantity\":2"))
        #expect(!text.contains("2.0"))

        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Booleans decode as booleans, not as numbers")
    func booleansAreNotNumbers() throws {
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"gift":true,"count":1}"#.utf8)
        )
        #expect(decoded["gift"] == .bool(true))
        #expect(decoded["count"] == .int(1))
    }

    @Test("Decoding into a model")
    func decodeIntoModel() throws {
        struct Contact: Decodable, Equatable {
            let fullName: String
            let email: String
        }

        let payload: JSONValue = ["fullName": "chirag", "email": "chirag@example.com"]
        #expect(
            try payload.decode(Contact.self)
                == Contact(fullName: "chirag", email: "chirag@example.com")
        )
    }

    @Test("Decoding into JSONValue is an identity")
    func decodeIntoJSONValue() throws {
        let payload: JSONValue = ["extras": ["bag", "legroom"]]
        #expect(try payload.decode(JSONValue.self) == payload)
    }

    @Test("Encoding an Encodable model")
    func encodeModel() throws {
        struct Seat: Encodable {
            let row = 4
            let letter = "A"
        }
        let value = try JSONValue(encoding: Seat())
        #expect(value == ["row": 4, "letter": "A"])
    }
}
