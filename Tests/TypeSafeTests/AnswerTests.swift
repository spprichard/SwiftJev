import Foundation
import Testing
@testable import TypeSafe

@Suite struct AnswerTests {
    let response = try! JSONDecoder().decode(SystemOneResponse.self, from: Data(liveSystemOneJSON.utf8))

    @Test func decodesTheLiveResponse() throws {
        #expect(response.model == "jev-1.13.0")
        #expect(response.usage == Usage(inputTokens: 372, outputTokens: 73))
        #expect(response.answers.count == 3)
        #expect(response.requestID == nil)
    }

    @Test func noulAnswer() throws {
        let urgent = try response.noul("is_urgent")
        #expect(urgent.noul == 0.95)
        #expect(urgent.probability == 0.95)
        #expect(response["is_urgent"]?.confidence == nil)
        #expect(response["is_urgent"]?.typeName == "noul")
    }

    @Test func choiceAnswer() throws {
        enum Department: String { case billing, technical, sales }

        let department = try response.choice("dept")
        #expect(department.choice == "billing")
        #expect(department.confidence == 0.97)
        #expect(department.probabilities == ["billing": 0.98, "sales": 0.0, "technical": 0.02])
        #expect(department.choice(as: Department.self) == .billing)
        #expect(department.ranked.map(\.option) == ["billing", "technical", "sales"])
        #expect(response["dept"]?.confidence == 0.97)
    }

    @Test func scoreAnswer() throws {
        let frustration = try response.score("frustration")
        #expect(frustration.score == 1.04)
        #expect(frustration.confidence == 0.94)
        #expect(frustration.legend == [0: "Calm", 1: "Frustrated", 2: "Very angry"])
        #expect(frustration.probabilities == [0: 0.0, 1: 0.96, 2: 0.04])
        #expect(frustration.levelCount == 3)
        #expect(frustration.normalizedScore == 0.52)
        #expect(frustration.mostLikelyLevel == 1)
        #expect(frustration.nearestLevel == 1)
        #expect(frustration.description(ofLevel: 2) == "Very angry")
        #expect(frustration.description(ofLevel: 7) == nil)
    }

    @Test func typedAccessorsThrowOnMissingOrMismatch() {
        #expect(throws: TypeSafeError.self) { try response.noul("nope") }
        #expect(throws: TypeSafeError.self) { try response.noul("dept") }
        #expect(throws: TypeSafeError.self) { try response.score("is_urgent") }
        #expect(throws: TypeSafeError.self) { try response.choice("frustration") }

        do {
            _ = try response.choice("is_urgent")
            Issue.record("expected a mismatch")
        } catch let TypeSafeError.answerTypeMismatch(id, expected, actual) {
            #expect(id == "is_urgent")
            #expect(expected == "choice")
            #expect(actual == "noul")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func answersRoundTripThroughCodable() throws {
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(SystemOneResponse.self, from: data)
        #expect(decoded == response)
    }

    @Test func scoreLevelKeysMustBeIntegers() {
        let bad = Data(#"{"type":"score","score":1,"confidence":1,"legend":{"one":"x"},"probabilities":{"one":1}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Answer.self, from: bad)
        }
    }

    @Test func modelCardsDecode() throws {
        let list = try JSONDecoder().decode(ListModelsResponse.self, from: Data(liveModelsJSON.utf8))
        #expect(list.models.map(\.name) == ["jev-latest", "jev-preview"])
        #expect(list.models[0].releaseDate == "2026-09-10T18:38:01.391457+00:00")
    }
}
