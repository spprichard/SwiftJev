import Foundation
import Logging
import Testing
@testable import TypeSafe

/// A transport that replays scripted outcomes and records what it was sent.
actor MockTransport: HTTPTransport {
    enum Outcome {
        case response(HTTPResponse)
        case error(any Error)
    }

    private(set) var requests: [HTTPRequest] = []
    private var script: [Outcome]

    init(_ script: [Outcome]) {
        self.script = script
    }

    init(status: Int = 200, headers: [String: String] = [:], json: String) {
        self.init([.response(HTTPResponse(status: status, headers: headers, body: Data(json.utf8)))])
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !script.isEmpty else {
            Issue.record("MockTransport ran out of scripted outcomes (request #\(requests.count))")
            throw TypeSafeError.connection(underlying: URLError(.unknown))
        }
        switch script.removeFirst() {
        case .response(let response): return response
        case .error(let error): throw error
        }
    }

    /// The last request's body decoded as JSON.
    func lastBody() throws -> JSONValue {
        let body = try #require(requests.last?.body)
        return try JSONDecoder().decode(JSONValue.self, from: body)
    }
}

extension RetryPolicy {
    /// The default policy with delays too short to notice.
    static var fast: RetryPolicy {
        var policy = RetryPolicy.default
        policy.backoffInitial = .milliseconds(1)
        policy.backoffMax = .milliseconds(2)
        return policy
    }
}

func makeClient(
    transport: some HTTPTransport,
    retryPolicy: RetryPolicy = .fast,
    environment: [String: String] = [:]
) throws -> TypeSafeClient {
    try TypeSafeClient(
        apiKey: "test-key",
        retryPolicy: retryPolicy,
        transport: transport,
        logger: Logger(label: "test"),
        environment: environment
    )
}

/// Captured from a live `POST /v1/systemone` call on 2026-09-20.
let liveSystemOneJSON = """
{"model":"jev-1.13.0","answers":{"is_urgent":{"type":"noul","noul":0.95},"dept":{"type":"choice","choice":"billing","confidence":0.97,"probabilities":{"billing":0.98,"sales":0.0,"technical":0.02}},"frustration":{"type":"score","score":1.04,"confidence":0.94,"legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},"probabilities":{"0":0.0,"1":0.96,"2":0.04}}},"usage":{"input_tokens":372,"output_tokens":73}}
"""

/// Captured from a live `GET /v1/models` call on 2026-09-20.
let liveModelsJSON = """
{"models":[{"name":"jev-latest","description":"The latest iteration of TypeSafe's System One Model: Jev","release_date":"2026-09-10T18:38:01.391457+00:00"},{"name":"jev-preview","description":"A preview version of `jev-latest`: should be better in most ways","release_date":"2026-09-10T18:39:06.057655+00:00"}]}
"""

func compactJSON(_ value: some JSONRepresentable) throws -> String {
    try value.jsonValue.serializedString()
}

/// `value` with every object's keys sorted, for comparing values that went
/// through `JSONDecoder` (which does not preserve key order).
func canonical(_ value: JSONValue) -> JSONValue {
    switch value {
    case .array(let values): .array(values.map(canonical))
    case .object(let object): JSONValue(Dictionary(uniqueKeysWithValues: object.map { ($0.key, canonical($0.value)) }))
    default: value
    }
}
