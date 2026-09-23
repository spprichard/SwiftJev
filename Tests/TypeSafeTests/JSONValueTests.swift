import Foundation
import Testing
@testable import TypeSafe

@Suite struct JSONValueTests {
    @Test func literalsBuildTheExpectedCases() {
        let value: JSONValue = [
            "text": "hi",
            "count": 2,
            "ratio": 0.5,
            "flag": true,
            "nothing": nil,
            "list": [1, "two", [3]],
            "nested": ["k": "v"],
        ]
        #expect(value["text"] == .string("hi"))
        #expect(value["count"] == .number(2))
        #expect(value["ratio"] == .number(0.5))
        #expect(value["flag"] == .bool(true))
        #expect(value["nothing"] == .null)
        #expect(value["list"]?[1] == .string("two"))
        #expect(value["list"]?[2]?[0]?.intValue == 3)
        #expect(value["nested"]?["k"]?.stringValue == "v")
        #expect(value["missing"] == nil)
        #expect(value["list"]?[9] == nil)
    }

    @Test func stringInterpolationWorks() {
        let id = "A-104"
        let value: JSONValue = "Order \(id)"
        #expect(value.stringValue == "Order A-104")
    }

    @Test func objectKeysKeepAuthoredOrder() throws {
        let value: JSONValue = ["zeta": 1, "alpha": 2, "mid": 3]
        #expect(try compactJSON(value) == #"{"zeta":1,"alpha":2,"mid":3}"#)
    }

    @Test func wholeNumbersEncodeWithoutFraction() throws {
        #expect(try compactJSON(JSONValue.number(49)) == "49")
        #expect(try compactJSON(JSONValue.number(1.5)) == "1.5")
        #expect(try compactJSON(JSONValue.number(-3)) == "-3")
    }

    @Test func roundTripsThroughCodable() throws {
        let original: JSONValue = [
            "ticket": ["subject": "Duplicate charge", "messages": [["from": "customer", "text": "Refund please"]]],
            "charges": [49, 49.5, nil, false],
            "policy": "Duplicate charges are eligible for a refund.",
        ]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: try original.serialized())
        #expect(canonical(decoded) == canonical(original))

        let viaEncoder = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(original))
        #expect(canonical(viaEncoder) == canonical(original))
    }

    @Test func serializerEscapesStrings() throws {
        let value: JSONValue = ["q": "say \"hi\"\n\ttab \\ slash / ünïcödé \u{01}"]
        let text = try value.serializedString()
        #expect(text == #"{"q":"say \"hi\"\n\ttab \\ slash / ünïcödé \u0001"}"#)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == value)
    }

    @Test func serializerRejectsNonFiniteNumbers() {
        #expect(throws: EncodingError.self) { try JSONValue.number(.infinity).serialized() }
        #expect(throws: EncodingError.self) { try JSONValue.number(.nan).serialized() }
    }

    @Test func decodesEveryScalarKind() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true, 1, 1.5, "s", null, {}, []]"#.utf8))
        #expect(decoded == [true, 1, 1.5, "s", nil, [:], []])
        #expect(decoded[0]?.boolValue == true)
        #expect(decoded[1]?.intValue == 1)
        #expect(decoded[2]?.intValue == nil)
    }

    @Test func wrapsEncodableValues() throws {
        struct Order: Encodable {
            let id: String
            let amounts: [Int]
        }
        let value = try JSONValue(encoding: Order(id: "A-104", amounts: [49, 49]))
        #expect(value["id"]?.stringValue == "A-104")
        #expect(value["amounts"]?.arrayValue?.count == 2)
    }

    @Test func decodesIntoDecodableValues() throws {
        struct Order: Decodable, Equatable {
            let id: String
        }
        let value: JSONValue = ["id": "A-104"]
        #expect(try value.decode(Order.self) == Order(id: "A-104"))
    }

    @Test func unorderedDictionaryInitSortsKeys() throws {
        let value = JSONValue(["b": 1, "a": 2, "c": 3] as [String: JSONValue])
        #expect(try compactJSON(value) == #"{"a":2,"b":1,"c":3}"#)
    }

    @Test func descriptionIsCompactJSON() {
        let value: JSONValue = ["a": [1, "x/y"]]
        #expect(value.description == #"{"a":[1,"x/y"]}"#)
    }
}
