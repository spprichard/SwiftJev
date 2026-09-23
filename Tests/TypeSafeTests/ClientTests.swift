import Foundation
import Testing
@testable import TypeSafe

@Suite struct ClientTests {
    @Test func sendsTheDocumentedRequest() async throws {
        let transport = MockTransport(headers: ["X-TypeSafe-Request-Id": "req_123"], json: liveSystemOneJSON)
        let client = try makeClient(transport: transport)

        let response = try await client.systemOne(
            state: "Help! My payouts have been failing for 3 days.",
            questions: ["is_urgent": .noul("Does this convey urgency?")]
        )

        #expect(response.requestID == "req_123")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(request.headers["Authorization"] == "Bearer test-key")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["User-Agent"] == "typesafe-swift/\(TypeSafeClient.version)")
        #expect(request.timeout == .seconds(10))
        let body = try #require(request.body)
        #expect(String(decoding: body, as: UTF8.self) == #"{"state":"Help! My payouts have been failing for 3 days.","model":"jev-latest","questions":{"is_urgent":{"type":"noul","instructions":"Does this convey urgency?"}}}"#)
    }

    @Test func modelOverridePrecedence() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 200, body: Data(liveSystemOneJSON.utf8))),
            .response(HTTPResponse(status: 200, body: Data(liveSystemOneJSON.utf8))),
        ])
        let client = try TypeSafeClient(
            apiKey: "k", transport: transport,
            environment: [TypeSafeClient.Environment.defaultModel: "jev-preview"]
        )
        #expect(client.defaultModel == "jev-preview")

        _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
        #expect(try await transport.lastBody()["model"] == "jev-preview")

        _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")], model: "jev-1.13.0")
        #expect(try await transport.lastBody()["model"] == "jev-1.13.0")
    }

    @Test func configurationFallsBackToEnvironment() throws {
        let environment = [
            TypeSafeClient.Environment.apiKey: "env-key",
            TypeSafeClient.Environment.baseURL: "https://example.test",
        ]
        let client = try TypeSafeClient(transport: MockTransport([]), environment: environment)
        #expect(client.baseURL.absoluteString == "https://example.test")
        #expect(client.defaultModel == "jev-latest")

        #expect(throws: TypeSafeError.self) {
            try TypeSafeClient(transport: MockTransport([]), environment: [:])
        }
        #expect(throws: TypeSafeError.self) {
            try TypeSafeClient(apiKey: "", transport: MockTransport([]), environment: [:])
        }
    }

    @Test func perCallOptionsOverrideHeadersAndTimeout() async throws {
        let transport = MockTransport(json: liveSystemOneJSON)
        let client = try TypeSafeClient(
            apiKey: "k", defaultHeaders: ["X-Team": "a", "X-Trace": "keep"], transport: transport, environment: [:]
        )
        _ = try await client.systemOne(
            state: "s", questions: ["q": .noul("?")],
            options: RequestOptions(headers: ["X-Team": "b"], timeout: .seconds(3))
        )
        let request = try #require(await transport.requests.first)
        #expect(request.headers["X-Team"] == "b")
        #expect(request.headers["X-Trace"] == "keep")
        #expect(request.timeout == .seconds(3))
    }

    @Test func emptyQuestionsAreRejectedBeforeSending() async throws {
        let transport = MockTransport([])
        let client = try makeClient(transport: transport)
        await #expect(throws: TypeSafeError.self) {
            try await client.systemOne(state: "s", questions: [:])
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func listModels() async throws {
        let transport = MockTransport(json: liveModelsJSON)
        let client = try makeClient(transport: transport)
        let models = try await client.listModels()
        #expect(models.map(\.name) == ["jev-latest", "jev-preview"])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.typesafe.ai/v1/models")
        #expect(request.body == nil)
        #expect(request.headers["Content-Type"] == nil)
    }

    @Test func nonRetryableStatusesThrowImmediately() async throws {
        let transport = MockTransport(
            status: 422,
            headers: ["x-typesafe-request-id": "req_422"],
            json: #"{"detail":[{"loc":["body","questions","q","criteria"],"msg":"field required"}]}"#
        )
        let client = try makeClient(transport: transport)
        do {
            _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
            Issue.record("expected an API error")
        } catch let TypeSafeError.api(error) {
            #expect(error.status == 422)
            #expect(error.kind == .unprocessableEntity)
            #expect(error.requestID == "req_422")
            #expect(error.body?["detail"]?[0]?["msg"]?.stringValue == "field required")
            #expect(error.description.contains("422"))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func statusKindsMap() {
        #expect(APIError.Kind(status: 400) == .badRequest)
        #expect(APIError.Kind(status: 401) == .authentication)
        #expect(APIError.Kind(status: 403) == .permissionDenied)
        #expect(APIError.Kind(status: 404) == .notFound)
        #expect(APIError.Kind(status: 422) == .unprocessableEntity)
        #expect(APIError.Kind(status: 429) == .rateLimited)
        #expect(APIError.Kind(status: 529) == .overloaded)
        #expect(APIError.Kind(status: 503) == .server)
        #expect(APIError.Kind(status: 418) == .other)
    }

    @Test func errorMessagesAreExtractedFromEveryDetailShape() {
        func error(_ json: String) -> APIError {
            APIError(response: HTTPResponse(status: 400, body: Data(json.utf8)))
        }
        // The three `detail` shapes observed from the live API on 2026-09-20.
        #expect(error(#"{"detail":"Too many score levels. Must have at most 10 levels."}"#).message == "Too many score levels. Must have at most 10 levels.")
        let typed = error(#"{"detail":{"error_type":"api_usage_error","message":"Unknown model: nope"}}"#)
        #expect(typed.message == "Unknown model: nope")
        #expect(typed.errorType == "api_usage_error")
        let fields = error(#"{"detail":[{"type":"missing","loc":["body","questions","q","choice","criteria"],"msg":"Field required"}]}"#)
        #expect(fields.message?.contains(#""msg":"Field required""#) == true)
        #expect(fields.errorType == nil)
    }

    @Test func nonJSONErrorBodiesAreKeptAsText() {
        let error = APIError(response: HTTPResponse(status: 502, body: Data("Bad Gateway".utf8)))
        #expect(error.body == .string("Bad Gateway"))
        #expect(error.message == "Bad Gateway")
        #expect(APIError(response: HTTPResponse(status: 500)).body == nil)
    }

    @Test func undecodableSuccessBodyIsReported() async throws {
        let transport = MockTransport(json: #"{"unexpected": true}"#)
        let client = try makeClient(transport: transport)
        do {
            _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
            Issue.record("expected a decoding error")
        } catch let TypeSafeError.decoding(_, body) {
            #expect(String(decoding: body, as: UTF8.self) == #"{"unexpected": true}"#)
        }
    }
}
