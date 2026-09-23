import Foundation
import Testing
@testable import TypeSafe

@Suite struct RetryTests {
    private func ok() -> MockTransport.Outcome {
        .response(HTTPResponse(status: 200, body: Data(liveSystemOneJSON.utf8)))
    }

    @Test func retriesRateLimitsThenSucceeds() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 429, headers: ["retry-after-ms": "1"])),
            .response(HTTPResponse(status: 529)),
            ok(),
        ])
        let client = try makeClient(transport: transport)
        let response = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
        #expect(response.model == "jev-1.13.0")
        #expect(await transport.requests.count == 3)
    }

    @Test func givesUpAfterMaxRetries() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 503)),
            .response(HTTPResponse(status: 503)),
            .response(HTTPResponse(status: 503)),
            ok(),
        ])
        let client = try makeClient(transport: transport)
        do {
            _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
            Issue.record("expected failure")
        } catch let TypeSafeError.api(error) {
            #expect(error.status == 503)
        }
        #expect(await transport.requests.count == 3)  // 1 attempt + 2 retries
    }

    @Test func retriesCanBeDisabled() async throws {
        let transport = MockTransport([.response(HTTPResponse(status: 429)), ok()])
        let client = try makeClient(transport: transport, retryPolicy: .noRetries)
        await #expect(throws: TypeSafeError.self) {
            try await client.systemOne(state: "s", questions: ["q": .noul("?")])
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func perCallPolicyOverridesClientPolicy() async throws {
        let transport = MockTransport([.response(HTTPResponse(status: 429)), ok()])
        let client = try makeClient(transport: transport)
        await #expect(throws: TypeSafeError.self) {
            try await client.systemOne(
                state: "s", questions: ["q": .noul("?")],
                options: RequestOptions(retryPolicy: .noRetries)
            )
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func retriesConnectionErrorsAndTimeouts() async throws {
        let transport = MockTransport([
            .error(TypeSafeError.connection(underlying: URLError(.networkConnectionLost))),
            .error(TypeSafeError.timeout(10)),
            ok(),
        ])
        let client = try makeClient(transport: transport)
        _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
        #expect(await transport.requests.count == 3)
    }

    @Test func foreignTransportErrorsCountAsConnectionErrors() async throws {
        struct Boom: Error {}
        let transport = MockTransport([.error(Boom()), ok()])
        let client = try makeClient(transport: transport)
        _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
        #expect(await transport.requests.count == 2)

        var policy = RetryPolicy.fast
        policy.retryConnectionErrors = false
        let strict = try makeClient(transport: MockTransport([.error(Boom()), ok()]), retryPolicy: policy)
        do {
            _ = try await strict.systemOne(state: "s", questions: ["q": .noul("?")])
            Issue.record("expected failure")
        } catch TypeSafeError.connection(let underlying) {
            #expect(underlying is Boom)
        }
    }

    @Test func honorsRetryAfterHeaders() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 429, headers: ["Retry-After": "0"])),
            ok(),
        ])
        let client = try makeClient(transport: transport)
        let started = ContinuousClock.now
        _ = try await client.systemOne(state: "s", questions: ["q": .noul("?")])
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func retryAfterParsing() {
        #expect(HTTPResponse(status: 429, headers: ["retry-after-ms": "1500"]).retryAfter == .milliseconds(1500))
        #expect(HTTPResponse(status: 429, headers: ["Retry-After": "2"]).retryAfter == .seconds(2))
        #expect(HTTPResponse(status: 429, headers: ["retry-after-ms": "5", "Retry-After": "2"]).retryAfter == .milliseconds(5))
        #expect(HTTPResponse(status: 429, headers: ["Retry-After": "garbage"]).retryAfter == nil)
        #expect(HTTPResponse(status: 429).retryAfter == nil)

        let soon = Date(timeIntervalSinceNow: 30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let parsed = HTTPResponse(status: 429, headers: ["Retry-After": formatter.string(from: soon)]).retryAfter
        let seconds = try! #require(parsed).seconds
        #expect(seconds > 25 && seconds <= 30)
    }

    @Test func retryAfterBeyondCapFallsBackToBackoff() {
        var policy = RetryPolicy.default
        policy.backoffJitter = 0
        #expect(policy.delay(attempt: 0, retryAfter: .seconds(120)) == .milliseconds(500))
        #expect(policy.delay(attempt: 0, retryAfter: .seconds(3)) == .seconds(3))
        policy.respectRetryAfter = false
        #expect(policy.delay(attempt: 1, retryAfter: .seconds(3)) == .seconds(1))
    }

    @Test func backoffDoublesAndCaps() {
        var policy = RetryPolicy.default
        policy.backoffJitter = 0
        #expect(policy.backoff(attempt: 0) == .milliseconds(500))
        #expect(policy.backoff(attempt: 1) == .seconds(1))
        #expect(policy.backoff(attempt: 2) == .seconds(2))
        #expect(policy.backoff(attempt: 3) == .seconds(4))
        #expect(policy.backoff(attempt: 4) == .seconds(5))
        #expect(policy.backoff(attempt: 10) == .seconds(5))

        policy.backoffJitter = 0.25
        for attempt in 0..<5 {
            let delay = policy.backoff(attempt: attempt).seconds
            let full = min(0.5 * pow(2, Double(attempt)), 5)
            #expect(delay <= full && delay >= full * 0.75)
        }
    }

    @Test func cancellationStopsRetrying() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 429, headers: ["Retry-After": "5"])),
            ok(),
        ])
        let client = try makeClient(transport: transport, retryPolicy: .default)
        let task = Task {
            try await client.systemOne(state: "s", questions: ["q": .noul("?")])
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await transport.requests.count == 1)
    }
}
