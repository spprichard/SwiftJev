import Foundation
import Logging

/// A client for TypeSafe's System One API.
///
/// ```swift
/// let client = try TypeSafeClient()  // reads TYPESAFE_API_KEY
/// let response = try await client.systemOne(
///     state: "Help! My payouts have been failing for 3 days.",
///     questions: [
///         "is_urgent": .noul("Does this convey urgency?"),
///         "department": .choice("Which team should handle this?", criteria: [
///             "billing": "Payments, invoicing, refunds",
///             "technical": "Bugs, outages, integrations",
///         ]),
///     ]
/// )
/// let urgent = try response.noul("is_urgent").noul > 0.8
/// let department = try response.choice("department")
/// ```
///
/// The client is immutable and safe to share across tasks. Explicit
/// initializer arguments win over environment variables, which win over
/// built-in defaults.
public final class TypeSafeClient: Sendable {
    /// Environment variables the client reads when an argument is omitted.
    public enum Environment {
        public static let apiKey = "TYPESAFE_API_KEY"
        public static let baseURL = "TYPESAFE_BASE_URL"
        public static let defaultModel = "TYPESAFE_DEFAULT_MODEL"
    }

    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!
    public static let defaultModel = "jev-latest"
    public static let version = "0.1.0"

    public let baseURL: URL
    public let defaultModel: String
    public let timeout: Duration
    public let retryPolicy: RetryPolicy
    public let defaultHeaders: [String: String]
    public let transport: any HTTPTransport
    public let logger: Logger

    private let apiKey: String
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - apiKey: Falls back to `TYPESAFE_API_KEY`.
    ///   - baseURL: Falls back to `TYPESAFE_BASE_URL`, then `https://api.typesafe.ai`.
    ///   - defaultModel: Falls back to `TYPESAFE_DEFAULT_MODEL`, then `jev-latest`.
    ///   - timeout: Per attempt; retries are not bounded by a total budget.
    ///   - retryPolicy: See ``RetryPolicy`` for the defaults.
    ///   - defaultHeaders: Sent with every request; per-call headers win.
    ///   - transport: Swap in another HTTP client or a test stub.
    ///   - logger: Request summaries log at `.debug`; bodies at `.trace`.
    ///   - environment: Where fallbacks are read from; injectable for tests.
    /// - Throws: ``TypeSafeError/missingAPIKey`` when no key can be found.
    public init(
        apiKey: String? = nil,
        baseURL: URL? = nil,
        defaultModel: String? = nil,
        timeout: Duration = .seconds(10),
        retryPolicy: RetryPolicy = .default,
        defaultHeaders: [String: String] = [:],
        transport: any HTTPTransport = URLSessionTransport(),
        logger: Logger = Logger(label: "ai.typesafe.sdk"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let apiKey = apiKey ?? environment[Environment.apiKey], !apiKey.isEmpty else {
            throw TypeSafeError.missingAPIKey
        }
        self.apiKey = apiKey
        self.baseURL = baseURL ?? environment[Environment.baseURL].flatMap(URL.init(string:)) ?? Self.defaultBaseURL
        self.defaultModel = defaultModel ?? environment[Environment.defaultModel] ?? Self.defaultModel
        self.timeout = timeout
        self.retryPolicy = retryPolicy
        self.defaultHeaders = defaultHeaders
        self.transport = transport
        self.logger = logger
    }

    // MARK: - System One

    /// Evaluates `state` against `questions` and returns one typed answer per question.
    ///
    /// Put every question that uses the same state in one call: the model
    /// evaluates them in parallel, so extra questions add little latency and
    /// cost only their own tokens.
    ///
    /// - Parameters:
    ///   - state: The content to evaluate. A string, or a dictionary/array literal.
    ///   - questions: Keyed by the IDs you want the answers under.
    ///   - model: Overrides the client's default model for this call.
    public func systemOne(
        state: JSONValue,
        questions: Questions,
        model: String? = nil,
        options: RequestOptions = RequestOptions()
    ) async throws -> SystemOneResponse {
        try await systemOne(SystemOneRequest(state: state, questions: questions, model: model), options: options)
    }

    /// Sends a prebuilt request. `request.model` of `nil` uses the client default.
    public func systemOne(_ request: SystemOneRequest, options: RequestOptions = RequestOptions()) async throws -> SystemOneResponse {
        guard !request.questions.isEmpty else {
            throw TypeSafeError.invalidRequest("questions must contain at least one question")
        }
        var request = request
        request.model = request.model ?? defaultModel

        let body: Data
        do {
            body = try request.jsonValue.serialized()
        } catch {
            throw TypeSafeError.invalidRequest("could not encode request: \(error)")
        }

        let http = try await send(method: "POST", path: "/v1/systemone", body: body, options: options)
        var response: SystemOneResponse = try decode(http)
        response.requestID = http.requestID
        return response
    }

    // MARK: - Models

    /// Lists the models available to the account.
    public func listModels(options: RequestOptions = RequestOptions()) async throws -> [ModelCard] {
        let http = try await send(method: "GET", path: "/v1/models", body: nil, options: options)
        let list: ListModelsResponse = try decode(http)
        return list.models
    }

    // MARK: - Transport

    private func send(method: String, path: String, body: Data?, options: RequestOptions) async throws -> HTTPResponse {
        var headers = defaultHeaders
        headers["Authorization"] = "Bearer \(apiKey)"
        headers["Accept"] = "application/json"
        headers["User-Agent"] = "typesafe-swift/\(Self.version)"
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        for (name, value) in options.headers {
            headers[name] = value
        }

        let request = HTTPRequest(
            method: method,
            url: baseURL.appending(path: path),
            headers: headers,
            body: body,
            timeout: options.timeout ?? timeout
        )
        let policy = options.retryPolicy ?? retryPolicy

        var attempt = 0
        while true {
            try Task.checkCancellation()
            logger.trace("→ \(method) \(request.url)", metadata: ["attempt": "\(attempt)", "body": "\(body.map { String(decoding: $0, as: UTF8.self) } ?? "")"])
            let started = ContinuousClock.now

            let outcome: Result<HTTPResponse, TypeSafeError>
            do {
                outcome = .success(try await transport.send(request))
            } catch let error as TypeSafeError {
                outcome = .failure(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome = .failure(.connection(underlying: error))
            }

            let elapsed = ContinuousClock.now - started
            let delay: Duration
            switch outcome {
            case .success(let response):
                logger.debug("← \(response.status) \(method) \(path)", metadata: [
                    "attempt": "\(attempt)",
                    "elapsed_ms": "\(Int(elapsed.seconds * 1000))",
                    "request_id": "\(response.requestID ?? "-")",
                ])
                logger.trace("← body", metadata: ["body": "\(String(decoding: response.body, as: UTF8.self))"])
                if (200..<300).contains(response.status) {
                    return response
                }
                let error = APIError(response: response)
                guard attempt < policy.maxRetries, policy.httpStatuses.contains(response.status) else {
                    throw TypeSafeError.api(error)
                }
                delay = policy.delay(attempt: attempt, retryAfter: error.retryAfter)

            case .failure(let error):
                let retryable: Bool
                switch error {
                case .connection: retryable = policy.retryConnectionErrors
                case .timeout: retryable = policy.retryTimeouts
                default: retryable = false
                }
                logger.debug("✗ \(method) \(path): \(error)", metadata: ["attempt": "\(attempt)"])
                guard attempt < policy.maxRetries, retryable else { throw error }
                delay = policy.backoff(attempt: attempt)
            }

            attempt += 1
            logger.debug("retrying \(method) \(path)", metadata: ["attempt": "\(attempt)", "delay_ms": "\(Int(delay.seconds * 1000))"])
            try await Task.sleep(for: delay)
        }
    }

    private func decode<T: Decodable>(_ response: HTTPResponse) throws -> T {
        do {
            return try decoder.decode(T.self, from: response.body)
        } catch {
            throw TypeSafeError.decoding(underlying: error, body: response.body)
        }
    }
}
