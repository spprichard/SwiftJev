import Foundation

/// The typed answer to one question, under the same ID you gave the question.
public enum Answer: Sendable, Hashable {
    case choice(ChoiceAnswer)
    case score(ScoreAnswer)
    case noul(NoulAnswer)

    /// The wire name of this answer's type: `"choice"`, `"score"`, or `"noul"`.
    public var typeName: String {
        switch self {
        case .choice: "choice"
        case .score: "score"
        case .noul: "noul"
        }
    }

    public var choiceAnswer: ChoiceAnswer? {
        if case .choice(let answer) = self { return answer }
        return nil
    }

    public var scoreAnswer: ScoreAnswer? {
        if case .score(let answer) = self { return answer }
        return nil
    }

    public var noulAnswer: NoulAnswer? {
        if case .noul(let answer) = self { return answer }
        return nil
    }

    /// How peaked the answer's probability distribution is, from 0 to 1.
    /// `nil` for Noul answers, which carry no separate confidence.
    public var confidence: Double? {
        switch self {
        case .choice(let answer): answer.confidence
        case .score(let answer): answer.confidence
        case .noul: nil
        }
    }
}

// MARK: - Choice

/// The answer to a ``Choice`` question.
public struct ChoiceAnswer: Sendable, Hashable, Codable {
    /// The highest-probability option.
    public let choice: String

    /// Every option mapped to its probability. The values sum to 1.
    public let probabilities: [String: Double]

    /// How certain the model is, derived from `probabilities`. See
    /// https://docs.typesafe.ai/confidence for how to threshold it.
    public let confidence: Double

    public init(choice: String, probabilities: [String: Double], confidence: Double) {
        self.choice = choice
        self.probabilities = probabilities
        self.confidence = confidence
    }

    /// The chosen option as a `String`-backed enum, or `nil` if it doesn't match a case.
    public func choice<Option: RawRepresentable>(as type: Option.Type = Option.self) -> Option?
    where Option.RawValue == String {
        Option(rawValue: choice)
    }

    /// Options ordered from most to least likely.
    public var ranked: [(option: String, probability: Double)] {
        probabilities
            .map { (option: $0.key, probability: $0.value) }
            .sorted { lhs, rhs in
                lhs.probability != rhs.probability ? lhs.probability > rhs.probability : lhs.option < rhs.option
            }
    }
}

// MARK: - Score

/// The answer to a ``Score`` question.
public struct ScoreAnswer: Sendable, Hashable {
    /// The probability-weighted position along your levels, from 0 to
    /// `levelCount - 1`. It can fall between two levels.
    public let score: Double

    /// Each level number mapped back to the description you supplied.
    public let legend: [Int: JSONValue]

    /// Each level mapped to its probability. The values sum to 1.
    public let probabilities: [Int: Double]

    /// How certain the model is, derived from `probabilities`. See
    /// https://docs.typesafe.ai/confidence for how to threshold it.
    public let confidence: Double

    public init(score: Double, legend: [Int: JSONValue], probabilities: [Int: Double], confidence: Double) {
        self.score = score
        self.legend = legend
        self.probabilities = probabilities
        self.confidence = confidence
    }

    /// The number of levels in the rubric.
    public var levelCount: Int { legend.count }

    /// `score` rescaled to 0...1, so scores from rubrics with different level
    /// counts can be weighted together. `0` for a single-level rubric.
    public var normalizedScore: Double {
        levelCount > 1 ? score / Double(levelCount - 1) : 0
    }

    /// The level with the highest probability.
    public var mostLikelyLevel: Int {
        probabilities.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key ?? 0
    }

    /// `score` rounded to the nearest level.
    public var nearestLevel: Int {
        Int(score.rounded())
    }

    /// The description of a level, if it is a plain string.
    public func description(ofLevel level: Int) -> String? {
        legend[level]?.stringValue
    }
}

extension ScoreAnswer: Codable {
    private enum CodingKeys: String, CodingKey {
        case score, legend, probabilities, confidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = try container.decode(Double.self, forKey: .score)
        confidence = try container.decode(Double.self, forKey: .confidence)
        // The API keys these maps by the level number as a string ("0", "1", ...).
        // Swift would encode `[Int: _]` as a flat array, so convert by hand.
        legend = try Self.intKeyed(container.decode([String: JSONValue].self, forKey: .legend), container, .legend)
        probabilities = try Self.intKeyed(container.decode([String: Double].self, forKey: .probabilities), container, .probabilities)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(score, forKey: .score)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(Dictionary(uniqueKeysWithValues: legend.map { (String($0.key), $0.value) }), forKey: .legend)
        try container.encode(Dictionary(uniqueKeysWithValues: probabilities.map { (String($0.key), $0.value) }), forKey: .probabilities)
    }

    private static func intKeyed<Value>(
        _ stringKeyed: [String: Value],
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> [Int: Value] {
        var result: [Int: Value] = [:]
        result.reserveCapacity(stringKeyed.count)
        for (levelText, value) in stringKeyed {
            guard let level = Int(levelText) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container, debugDescription: "Level key \"\(levelText)\" is not an integer."
                )
            }
            result[level] = value
        }
        return result
    }
}

// MARK: - Noul

/// The answer to a ``Noul`` question.
public struct NoulAnswer: Sendable, Hashable, Codable {
    /// The probability that the answer is yes, from 0 to 1. Near 1 is a strong
    /// yes, near 0 a strong no, near 0.5 uncertain.
    public let noul: Double

    public init(noul: Double) {
        self.noul = noul
    }

    /// Alias for `noul`.
    public var probability: Double { noul }
}

// MARK: - Codable

extension Answer: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "choice": self = .choice(try ChoiceAnswer(from: decoder))
        case "score": self = .score(try ScoreAnswer(from: decoder))
        case "noul": self = .noul(try NoulAnswer(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown answer type \"\(type)\"."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .choice(let answer): try answer.encode(to: encoder)
        case .score(let answer): try answer.encode(to: encoder)
        case .noul(let answer): try answer.encode(to: encoder)
        }
    }
}
