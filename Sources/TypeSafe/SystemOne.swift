import Foundation
import OrderedCollections

/// The body of `POST /v1/systemone`: one state, one model, and the questions
/// to evaluate against that state.
public struct SystemOneRequest: Sendable, Hashable {
    /// The content to evaluate: a string, or an object/array of related context.
    public var state: JSONValue

    /// The model that handles the request, such as `"jev-latest"`. `nil` uses
    /// the client's default model.
    public var model: String?

    /// The questions, keyed by the IDs you choose.
    public var questions: Questions

    public init(state: JSONValue, questions: Questions, model: String? = nil) {
        self.state = state
        self.questions = questions
        self.model = model
    }
}

extension SystemOneRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case state, model, questions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(JSONValue.self, forKey: .state)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        questions = try Questions(decodingObjectFrom: container.superDecoder(forKey: .questions))
    }

    /// Encodes the same shape as ``jsonValue``. `JSONEncoder` does not
    /// preserve key order; the client sends ``JSONValue/serialized()`` instead.
    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }
}

extension SystemOneRequest: JSONRepresentable {
    /// The request body as it is sent on the wire.
    public var jsonValue: JSONValue {
        var object: JSONObject = ["state": state]
        if let model {
            object["model"] = .string(model)
        }
        var questionsObject = JSONObject(minimumCapacity: questions.count)
        for (id, question) in questions {
            questionsObject[id] = question.jsonValue
        }
        object["questions"] = .object(questionsObject)
        return .object(object)
    }
}

/// The response to a System One request: one answer per question, plus the
/// model that ran and the tokens it used.
public struct SystemOneResponse: Sendable, Hashable {
    /// The model that performed the evaluation, such as `"jev-1.13.0"`.
    public let model: String

    /// One answer per question, keyed by the IDs you used in the request.
    public let answers: [String: Answer]

    /// Token usage for the request.
    public let usage: Usage

    /// The `x-typesafe-request-id` response header, for support requests.
    public internal(set) var requestID: String?

    public init(model: String, answers: [String: Answer], usage: Usage, requestID: String? = nil) {
        self.model = model
        self.answers = answers
        self.usage = usage
        self.requestID = requestID
    }

    public subscript(id: String) -> Answer? {
        answers[id]
    }

    /// The answer to a Choice question.
    /// - Throws: ``TypeSafeError/answerMissing(id:)`` or ``TypeSafeError/answerTypeMismatch(id:expected:actual:)``.
    public func choice(_ id: String) throws -> ChoiceAnswer {
        let answer = try answer(id)
        guard let choice = answer.choiceAnswer else {
            throw TypeSafeError.answerTypeMismatch(id: id, expected: "choice", actual: answer.typeName)
        }
        return choice
    }

    /// The answer to a Score question.
    /// - Throws: ``TypeSafeError/answerMissing(id:)`` or ``TypeSafeError/answerTypeMismatch(id:expected:actual:)``.
    public func score(_ id: String) throws -> ScoreAnswer {
        let answer = try answer(id)
        guard let score = answer.scoreAnswer else {
            throw TypeSafeError.answerTypeMismatch(id: id, expected: "score", actual: answer.typeName)
        }
        return score
    }

    /// The answer to a Noul question.
    /// - Throws: ``TypeSafeError/answerMissing(id:)`` or ``TypeSafeError/answerTypeMismatch(id:expected:actual:)``.
    public func noul(_ id: String) throws -> NoulAnswer {
        let answer = try answer(id)
        guard let noul = answer.noulAnswer else {
            throw TypeSafeError.answerTypeMismatch(id: id, expected: "noul", actual: answer.typeName)
        }
        return noul
    }

    /// The answer under `id`, whatever its type.
    /// - Throws: ``TypeSafeError/answerMissing(id:)``.
    public func answer(_ id: String) throws -> Answer {
        guard let answer = answers[id] else { throw TypeSafeError.answerMissing(id: id) }
        return answer
    }
}

extension SystemOneResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case model, answers, usage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        answers = try container.decode([String: Answer].self, forKey: .answers)
        usage = try container.decode(Usage.self, forKey: .usage)
        requestID = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(answers, forKey: .answers)
        try container.encode(usage, forKey: .usage)
    }
}

/// Token usage for one request.
public struct Usage: Sendable, Hashable, Codable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

/// Metadata for a model available to the account, from `GET /v1/models`.
public struct ModelCard: Sendable, Hashable, Codable {
    /// The name to pass as `model`, such as `"jev-latest"`.
    public let name: String
    public let description: String

    /// The release timestamp as the API sent it (ISO 8601).
    public let releaseDate: String

    public init(name: String, description: String, releaseDate: String) {
        self.name = name
        self.description = description
        self.releaseDate = releaseDate
    }

    private enum CodingKeys: String, CodingKey {
        case name, description
        case releaseDate = "release_date"
    }
}

struct ListModelsResponse: Decodable {
    let models: [ModelCard]
}
