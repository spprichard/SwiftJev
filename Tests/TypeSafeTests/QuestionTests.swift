import Foundation
import Testing
@testable import TypeSafe

@Suite struct QuestionTests {
    @Test func noulEncodesWithoutCriteria() throws {
        let question = Question.noul("Does this convey urgency?")
        #expect(try compactJSON(question) == #"{"type":"noul","instructions":"Does this convey urgency?"}"#)
    }

    @Test func noulEncodesTrueFalseCriteria() throws {
        let question = Question.noul(
            "Does this convey urgency?",
            criteria: NoulCriteria(yes: "Explicitly time-sensitive", no: "No urgency expressed")
        )
        #expect(try compactJSON(question) == #"{"type":"noul","instructions":"Does this convey urgency?","criteria":{"true":"Explicitly time-sensitive","false":"No urgency expressed"}}"#)
    }

    @Test func choiceEncodesOrderedCriteriaWithNulls() throws {
        let question = Question.choice("Which team should handle this?", criteria: [
            "billing": "Payments, invoicing, refunds",
            "technical": "Bugs, outages, integrations",
            "other": nil,
        ])
        #expect(try compactJSON(question) == #"{"type":"choice","instructions":"Which team should handle this?","criteria":{"billing":"Payments, invoicing, refunds","technical":"Bugs, outages, integrations","other":null}}"#)
    }

    @Test func scoreEncodesOrderedLevels() throws {
        let question = Question.score("How frustrated is the customer?", criteria: ["Calm", "Frustrated", "Very angry"])
        #expect(try compactJSON(question) == #"{"type":"score","instructions":"How frustrated is the customer?","criteria":["Calm","Frustrated","Very angry"]}"#)
    }

    @Test func structuredInstructionsAndCriteriaAreAllowed() throws {
        let question = Question.noul([
            "potential_duplicate": ["name": "John Smith", "location": "Oakland, California"],
            "question": "Is the resume for the same person as `potential_duplicate`?",
        ])
        let json = try compactJSON(question)
        #expect(json.contains(#""instructions":{"potential_duplicate":{"name":"John Smith""#))

        let structuredScore = Question.score("Rate it", criteria: [["label": "low", "detail": "..."], "high"])
        #expect(try compactJSON(structuredScore).contains(#""criteria":[{"label":"low","detail":"..."},"high"]"#))
    }

    @Test func stringVariablesWorkAsInstructions() {
        let text = "Does `ticket_message` request a refund?"
        let question = Question.noul(text)
        #expect(question.instructions == .string(text))
        #expect(question.typeName == "noul")
    }

    @Test func questionsRoundTripThroughCodable() throws {
        let questions: Questions = [
            "a": .noul("A?", criteria: NoulCriteria(yes: "y")),
            "b": .choice("B?", criteria: ["x": "X", "y": nil]),
            "c": .score("C?", criteria: ["lo", "hi"]),
        ]
        let request = SystemOneRequest(state: "s", questions: questions, model: "jev-latest")
        let decoded = try JSONDecoder().decode(SystemOneRequest.self, from: try request.jsonValue.serialized())
        #expect(decoded.state == request.state)
        #expect(decoded.model == request.model)
        #expect(decoded.questions.count == 3)
        for (id, question) in questions {
            // Decoding does not preserve criteria order, so compare canonical forms.
            let roundTripped = try #require(decoded.questions[id])
            #expect(canonical(roundTripped.jsonValue) == canonical(question.jsonValue))
        }

        // Codable encodes the same shape, just without an order guarantee.
        let viaEncoder = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(request))
        #expect(canonical(viaEncoder) == canonical(request.jsonValue))
    }

    @Test func requestBodyMatchesTheDocumentedShape() throws {
        let request = SystemOneRequest(
            state: "Help! My payouts have been failing for 3 days.",
            questions: ["is_urgent": .noul("Does this convey urgency?")],
            model: "jev-latest"
        )
        #expect(try compactJSON(request) == #"{"state":"Help! My payouts have been failing for 3 days.","model":"jev-latest","questions":{"is_urgent":{"type":"noul","instructions":"Does this convey urgency?"}}}"#)
    }

    @Test func unknownQuestionTypeFailsToDecode() {
        let data = Data(#"{"type":"essay","instructions":"Write a poem"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Question.self, from: data)
        }
    }
}
