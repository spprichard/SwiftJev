import Foundation
import OrderedCollections

/// A JSON object whose keys keep the order they were written in.
///
/// The API reads `state`, `instructions`, and criteria as JSON, and key order is
/// the order the model sees, so this library preserves it rather than using
/// Swift's unordered `Dictionary`. Dictionary literals produce a `JSONObject`
/// directly.
public typealias JSONObject = OrderedDictionary<String, JSONValue>

/// Any JSON value.
///
/// Used wherever the API accepts free-form JSON: the `state` being evaluated,
/// a question's `instructions`, and the descriptions inside `criteria`. Build
/// one from literals:
///
/// ```swift
/// let state: JSONValue = [
///     "ticket": ["subject": "Duplicate charge", "order_id": "A-104"],
///     "charges": [49, 49],
///     "refund_policy": "Duplicate charges are eligible for a refund.",
/// ]
/// ```
///
/// or from any `Encodable` value with ``init(encoding:)``.
public enum JSONValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object(JSONObject)
}

/// A value with a canonical JSON form whose object keys are ordered.
public protocol JSONRepresentable {
    var jsonValue: JSONValue { get }
}

extension JSONValue: JSONRepresentable {
    public var jsonValue: JSONValue { self }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = JSONObject(minimumCapacity: elements.count)
        for (key, value) in elements {
            object[key] = value  // last duplicate wins, like a JSON parser
        }
        self = .object(object)
    }
}

// MARK: - Conversions

extension JSONValue {
    /// Wraps a `String`. Handy when the string is a variable rather than a literal.
    public init(_ string: String) { self = .string(string) }

    /// Wraps an integer.
    public init(_ int: Int) { self = .number(Double(int)) }

    /// Wraps a floating-point number.
    public init(_ double: Double) { self = .number(double) }

    /// Wraps a `Bool`.
    public init(_ bool: Bool) { self = .bool(bool) }

    /// Wraps an unordered dictionary. Keys are sorted so the output is deterministic;
    /// use a dictionary literal or ``JSONObject`` when you want a specific order.
    public init(_ dictionary: [String: JSONValue]) {
        var object = JSONObject(minimumCapacity: dictionary.count)
        for key in dictionary.keys.sorted() {
            object[key] = dictionary[key]
        }
        self = .object(object)
    }

    /// Wraps an ordered object.
    public init(_ object: JSONObject) { self = .object(object) }

    /// Wraps an array.
    public init(_ array: [JSONValue]) { self = .array(array) }

    /// Converts any `Encodable` value to JSON by round-tripping it through
    /// `JSONEncoder`. Key order follows the encoder's output.
    public init(encoding value: some Encodable, encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into any `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Accessors

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Looks up a key on an object; `nil` for other values or a missing key.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Looks up an index in an array; `nil` for other values or out-of-range indices.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let bool = try? single.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? single.decode(Int.self) {
            self = .number(Double(int))
        } else if let double = try? single.decode(Double.self) {
            self = .number(double)
        } else if let string = try? single.decode(String.self) {
            self = .string(string)
        } else if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            if let count = unkeyed.count { array.reserveCapacity(count) }
            while !unkeyed.isAtEnd {
                array.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(array)
        } else {
            let keyed = try decoder.container(keyedBy: AnyCodingKey.self)
            var object = JSONObject(minimumCapacity: keyed.allKeys.count)
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .number(let value):
            var single = encoder.singleValueContainer()
            // Emit `2` rather than `2.0` for whole numbers so output matches what
            // a JSON author would write.
            if let int = Int(exactly: value) {
                try single.encode(int)
            } else {
                try single.encode(value)
            }
        case .bool(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        case .array(let values):
            var unkeyed = encoder.unkeyedContainer()
            for value in values {
                try unkeyed.encode(value)
            }
        case .object(let object):
            try object.encodeAsObject(to: encoder)
        }
    }
}

extension JSONValue: CustomStringConvertible {
    /// Compact JSON text, with object keys in authored order.
    public var description: String {
        (try? serializedString()) ?? "<invalid JSON>"
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Compact JSON with object keys in authored order.
    ///
    /// `JSONEncoder` does not guarantee key order, so the client serializes
    /// request bodies with this instead. Throws for non-finite numbers, which
    /// JSON cannot represent.
    public func serialized() throws -> Data {
        Data(try serializedString().utf8)
    }

    /// `serialized()` as a `String`.
    public func serializedString() throws -> String {
        var output = ""
        try write(into: &output)
        return output
    }

    private func write(into output: inout String) throws {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "JSON cannot represent \(value)."))
            }
            if let int = Int(exactly: value) {
                output += String(int)
            } else {
                output += String(value)
            }
        case .string(let value):
            Self.writeEscaped(value, into: &output)
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                try value.write(into: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            for (index, (key, value)) in object.enumerated() {
                if index > 0 { output += "," }
                Self.writeEscaped(key, into: &output)
                output += ":"
                try value.write(into: &output)
            }
            output += "}"
        }
    }

    private static func writeEscaped(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case ..<" ":
                let hex = String(scalar.value, radix: 16, uppercase: true)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - Ordered object coding

/// A coding key made from any string, for encoding objects with dynamic keys.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension OrderedDictionary where Key == String, Value: Encodable {
    /// `OrderedDictionary`'s own `Codable` conformance writes a flat array of
    /// alternating keys and values. The API needs a JSON object, so encode it
    /// through a keyed container instead.
    func encodeAsObject(to encoder: any Encoder) throws {
        var keyed = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in self {
            try keyed.encode(value, forKey: AnyCodingKey(stringValue: key))
        }
    }
}

extension OrderedDictionary where Key == String, Value: Decodable {
    /// Counterpart of `encodeAsObject(to:)`.
    init(decodingObjectFrom decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(minimumCapacity: keyed.allKeys.count)
        for key in keyed.allKeys {
            self[key.stringValue] = try keyed.decode(Value.self, forKey: key)
        }
    }
}
