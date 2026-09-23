import Foundation
import Testing
@testable import TypeSafe

/// Hits the real API. Runs only when `TYPESAFE_API_KEY` is set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil))
struct IntegrationTests {
    /// No-retry tests get one attempt, so allow for a slow first connection
    /// (seen on GitHub macOS runners, where initial requests exceed 10s).
    static let noRetryTimeout: Duration = .seconds(30)

    @Test func evaluatesAllThreeQuestionTypes() async throws {
        let client = try TypeSafeClient()
        let response = try await client.systemOne(
            state: [
                "ticket_message": "My flight was cancelled. Can I get a refund?",
                "refund_policy": "Cancelled flights are eligible for a full refund.",
            ],
            questions: [
                "refund_requested": .noul("Does `ticket_message` request a refund?"),
                "request_type": .choice("What is the main request in `ticket_message`?", criteria: [
                    "refund": "The customer wants money returned.",
                    "rebooking": "The customer wants a replacement flight.",
                    "information": "The customer is asking for information only.",
                ]),
                "frustration": .score("How frustrated does the customer appear in `ticket_message`?", criteria: [
                    "Calm and neutral.",
                    "Concerned but civil.",
                    "Very angry or using strong language.",
                ]),
            ]
        )

        #expect(response.requestID?.hasPrefix("req_") == true)
        #expect(response.usage.inputTokens > 0)
        #expect(try response.noul("refund_requested").noul > 0.5)
        let type = try response.choice("request_type")
        #expect(type.choice == "refund")
        #expect(abs(type.probabilities.values.reduce(0, +) - 1) < 0.02)
        let frustration = try response.score("frustration")
        #expect(frustration.legend.count == 3)
        #expect((0...2).contains(frustration.score))
    }

    @Test func listsModels() async throws {
        let models = try await TypeSafeClient().listModels()
        #expect(models.contains { $0.name == "jev-latest" })
    }

    @Test func validationErrorsCarryTheServerMessage() async throws {
        let client = try TypeSafeClient(timeout: Self.noRetryTimeout, retryPolicy: .noRetries)
        do {
            let levels = (0...10).map { JSONValue("level \($0)") }
            _ = try await client.systemOne(state: "s", questions: ["q": .score("?", criteria: levels)])
            Issue.record("expected a 400")
        } catch let TypeSafeError.api(error) {
            #expect(error.kind == .badRequest)
            #expect(error.message?.contains("at most 10 levels") == true)
        }

        do {
            _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")], model: "not-a-model")
            Issue.record("expected a 400")
        } catch let TypeSafeError.api(error) {
            #expect(error.kind == .badRequest)
            #expect(error.errorType == "api_usage_error")
            #expect(error.message == "Unknown model: not-a-model")
        }
    }

    @Test func badKeyIs401() async throws {
        let client = try TypeSafeClient(apiKey: "not-a-key", timeout: Self.noRetryTimeout, retryPolicy: .noRetries)
        do {
            _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
            Issue.record("expected a 401")
        } catch let TypeSafeError.api(error) {
            #expect(error.kind == .authentication)
        }
    }
}
