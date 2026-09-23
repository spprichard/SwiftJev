import Foundation
import OrderedCollections

/// The questions in one request, keyed by the IDs you choose. Answers come
/// back under the same IDs. IDs are for your code only; they are not sent to
/// the model, so put the whole question in `instructions`.
public typealias Questions = OrderedDictionary<String, Question>

/// One judgment for the model to make about the state.
///
/// Build questions with the static helpers so the dictionary reads naturally:
///
/// ```swift
/// let questions: Questions = [
///     "refund_requested": .noul("Does `ticket_message` request a refund?"),
///     "department": .choice("Which team should handle this?", criteria: [
///         "billing": "Payments, invoicing, refunds",
///         "technical": "Bugs, outages, integrations",
///         "other": nil,
///     ]),
///     "frustration": .score("How frustrated is the customer?", criteria: [
///         "Calm", "Frustrated", "Very angry",
///     ]),
/// ]
/// ```
public enum Question: Sendable, Hashable {
    case choice(Choice)
    case score(Score)
    case noul(Noul)

    /// The wire name of this question's type: `"choice"`, `"score"`, or `"noul"`.
    public var typeName: String {
        switch self {
        case .choice: "choice"
        case .score: "score"
        case .noul: "noul"
        }
    }

    public var instructions: JSONValue {
        switch self {
        case .choice(let question): question.instructions
        case .score(let question): question.instructions
        case .noul(let question): question.instructions
        }
    }
}

extension Question: JSONRepresentable {
    /// The question as it is sent on the wire.
    public var jsonValue: JSONValue {
        switch self {
        case .choice(let question): question.jsonValue
        case .score(let question): question.jsonValue
        case .noul(let question): question.jsonValue
        }
    }
}

// MARK: - Convenience constructors

extension Question {
    /// A Choice question: pick one option from an unordered set.
    public static func choice(_ instructions: String, criteria: JSONObject) -> Question {
        .choice(Choice(instructions: instructions, criteria: criteria))
    }

    /// A Choice question with structured instructions.
    public static func choice(_ instructions: JSONValue, criteria: JSONObject) -> Question {
        .choice(Choice(instructions: instructions, criteria: criteria))
    }

    /// A Score question: rate the state along ordered levels.
    public static func score(_ instructions: String, criteria: [JSONValue]) -> Question {
        .score(Score(instructions: instructions, criteria: criteria))
    }

    /// A Score question with structured instructions.
    public static func score(_ instructions: JSONValue, criteria: [JSONValue]) -> Question {
        .score(Score(instructions: instructions, criteria: criteria))
    }

    /// A Noul question: the probability that a statement is true.
    public static func noul(_ instructions: String, criteria: NoulCriteria? = nil) -> Question {
        .noul(Noul(instructions: instructions, criteria: criteria))
    }

    /// A Noul question with structured instructions.
    public static func noul(_ instructions: JSONValue, criteria: NoulCriteria? = nil) -> Question {
        .noul(Noul(instructions: instructions, criteria: criteria))
    }
}

// MARK: - Choice

/// Picks one option from a set you define. The answer is the chosen option plus
/// the full probability distribution and a confidence.
///
/// Use it when the answer is one of a known set with no order between the
/// options: routing a ticket, classifying a document type. Add an `other` or
/// `none` option when the list might not cover every input. The API accepts up
/// to 255 options.
public struct Choice: Sendable, Hashable {
    /// What the model should decide. A string, or an object that holds the
    /// question in one field and data it refers to in others.
    public var instructions: JSONValue

    /// Option name to description. Use `nil` (JSON `null`) for an option that
    /// needs no description. Order is preserved on the wire.
    public var criteria: JSONObject

    public init(instructions: JSONValue, criteria: JSONObject) {
        self.instructions = instructions
        self.criteria = criteria
    }

    public init(instructions: String, criteria: JSONObject) {
        self.init(instructions: .string(instructions), criteria: criteria)
    }
}

extension Choice: JSONRepresentable {
    public var jsonValue: JSONValue {
        ["type": "choice", "instructions": instructions, "criteria": .object(criteria)]
    }
}

// MARK: - Score

/// Rates the state along an ordered rubric you define. The answer is a
/// probability-weighted position along the levels, which can fall between two
/// of them, plus the distribution and a confidence.
///
/// Use it when the answer belongs on a spectrum and you can describe each
/// point: severity, frustration, skill level. Provide at least two levels; the
/// API accepts up to 10.
public struct Score: Sendable, Hashable {
    /// What the model should rate.
    public var instructions: JSONValue

    /// Ordered level descriptions, lowest first. Level `n` in the answer's
    /// `legend` and `probabilities` is `criteria[n]`.
    public var criteria: [JSONValue]

    public init(instructions: JSONValue, criteria: [JSONValue]) {
        self.instructions = instructions
        self.criteria = criteria
    }

    public init(instructions: String, criteria: [JSONValue]) {
        self.init(instructions: .string(instructions), criteria: criteria)
    }
}

extension Score: JSONRepresentable {
    public var jsonValue: JSONValue {
        ["type": "score", "instructions": instructions, "criteria": .array(criteria)]
    }
}

// MARK: - Noul

/// A yes/no question. The answer is the probability that the answer is yes.
///
/// Use it when the probability itself is the useful signal and an `if` is the
/// natural consumer. Define the condition clearly: a value of 0.5 means the
/// model finds yes and no equally likely, not that the answer is "medium".
public struct Noul: Sendable, Hashable {
    /// The yes/no question.
    public var instructions: JSONValue

    /// Optional clarification of what yes and no mean.
    public var criteria: NoulCriteria?

    public init(instructions: JSONValue, criteria: NoulCriteria? = nil) {
        self.instructions = instructions
        self.criteria = criteria
    }

    public init(instructions: String, criteria: NoulCriteria? = nil) {
        self.init(instructions: .string(instructions), criteria: criteria)
    }
}

extension Noul: JSONRepresentable {
    public var jsonValue: JSONValue {
        var object: JSONObject = ["type": "noul", "instructions": instructions]
        if let criteria {
            object["criteria"] = criteria.jsonValue
        }
        return .object(object)
    }
}

/// Descriptions of what a yes and a no mean for a ``Noul`` question. Sent as
/// `{"true": ..., "false": ...}`.
public struct NoulCriteria: Sendable, Hashable, Codable {
    /// What a yes (value near 1) means.
    public var yes: JSONValue?

    /// What a no (value near 0) means.
    public var no: JSONValue?

    public init(yes: JSONValue? = nil, no: JSONValue? = nil) {
        self.yes = yes
        self.no = no
    }

    private enum CodingKeys: String, CodingKey {
        case yes = "true"
        case no = "false"
    }
}

extension NoulCriteria: JSONRepresentable {
    public var jsonValue: JSONValue {
        var object = JSONObject()
        if let yes { object["true"] = yes }
        if let no { object["false"] = no }
        return .object(object)
    }
}

// MARK: - Codable

extension Question: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let instructions = try container.decode(JSONValue.self, forKey: .instructions)
        switch type {
        case "choice":
            let criteria = try container.decode(JSONValue.self, forKey: .criteria)
            guard let object = criteria.objectValue else {
                throw DecodingError.dataCorruptedError(
                    forKey: .criteria, in: container, debugDescription: "Choice criteria must be a JSON object."
                )
            }
            self = .choice(Choice(instructions: instructions, criteria: object))
        case "score":
            let criteria = try container.decode([JSONValue].self, forKey: .criteria)
            self = .score(Score(instructions: instructions, criteria: criteria))
        case "noul":
            let criteria = try container.decodeIfPresent(NoulCriteria.self, forKey: .criteria)
            self = .noul(Noul(instructions: instructions, criteria: criteria))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown question type \"\(type)\"."
            )
        }
    }

    /// Encodes the same shape as ``jsonValue``. `JSONEncoder` does not
    /// preserve key order; use ``JSONValue/serialized()`` when order matters.
    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }
}
