import Foundation

/// Every error the client throws.
public enum TypeSafeError: Error, Sendable {
    /// No API key was given and `TYPESAFE_API_KEY` is not set.
    case missingAPIKey

    /// The request could not be built, for example because `questions` is empty.
    case invalidRequest(String)

    /// The API returned a non-2xx status. Inspect ``APIError/kind`` to branch.
    case api(APIError)

    /// The request never produced an HTTP response: DNS, TLS, or socket failure,
    /// or an interrupted response body. Retried by default.
    case connection(underlying: any Error)

    /// One attempt exceeded its timeout. Retried by default.
    case timeout(TimeInterval)

    /// The response was not the JSON this library expects.
    case decoding(underlying: any Error, body: Data)

    /// `SystemOneResponse.answers` has no entry under `id`.
    case answerMissing(id: String)

    /// The answer under `id` is a different type than the accessor asked for.
    case answerTypeMismatch(id: String, expected: String, actual: String)
}

/// A non-2xx response from the API.
public struct APIError: Error, Sendable {
    /// What the status code means. Use this to branch instead of comparing
    /// numbers.
    public enum Kind: Sendable, Hashable {
        /// 400. The request was malformed.
        case badRequest
        /// 401. Missing or invalid API key.
        case authentication
        /// 403. The key is valid but not allowed to do this.
        case permissionDenied
        /// 404.
        case notFound
        /// 422. The body failed validation; `body` names the offending field.
        case unprocessableEntity
        /// 429. Rate limit exceeded; back off and retry.
        case rateLimited
        /// 529. TypeSafe is temporarily overloaded; back off and retry.
        case overloaded
        /// Any other 5xx.
        case server
        /// Anything else.
        case other

        init(status: Int) {
            switch status {
            case 400: self = .badRequest
            case 401: self = .authentication
            case 403: self = .permissionDenied
            case 404: self = .notFound
            case 422: self = .unprocessableEntity
            case 429: self = .rateLimited
            case 529: self = .overloaded
            case 500...599: self = .server
            default: self = .other
            }
        }
    }

    /// HTTP status code.
    public let status: Int

    /// The meaning of `status`.
    public let kind: Kind

    /// The response body parsed as JSON, or `.string` if it wasn't JSON, or
    /// `nil` if it was empty.
    public let body: JSONValue?

    /// Response headers with lowercased names.
    public let headers: [String: String]

    /// The `x-typesafe-request-id` header, for support requests.
    public let requestID: String?

    /// How long the server asked us to wait, from `retry-after-ms` or
    /// `Retry-After`, when present.
    public let retryAfter: Duration?

    public init(status: Int, body: JSONValue?, headers: [String: String], requestID: String? = nil, retryAfter: Duration? = nil) {
        self.status = status
        self.kind = Kind(status: status)
        self.body = body
        self.headers = headers
        self.requestID = requestID
        self.retryAfter = retryAfter
    }

    init(response: HTTPResponse) {
        let body: JSONValue?
        if response.body.isEmpty {
            body = nil
        } else if let json = try? JSONDecoder().decode(JSONValue.self, from: response.body) {
            body = json
        } else {
            body = .string(String(decoding: response.body, as: UTF8.self))
        }
        self.init(
            status: response.status,
            body: body,
            headers: response.headers,
            requestID: response.requestID,
            retryAfter: response.retryAfter
        )
    }

    /// A human-readable message from the body. The API's `detail` field is a
    /// string (`"Too many score levels..."`), an object
    /// (`{"error_type": "api_usage_error", "message": "Unknown model: x"}`), or
    /// a list of field errors for a 422; this returns the text in the first
    /// two cases and the JSON in the last. `nil` for an empty body.
    public var message: String? {
        guard let body else { return nil }
        if let text = body.stringValue { return text }
        for key in ["detail", "message", "error"] {
            guard let value = body[key] else { continue }
            if let text = value.stringValue { return text }
            if let text = value["message"]?.stringValue { return text }
            return value.description
        }
        return body.description
    }

    /// The API's `error_type` when it sends one, such as `"api_usage_error"`.
    public var errorType: String? {
        body?["detail"]?["error_type"]?.stringValue
    }
}

extension APIError: CustomStringConvertible {
    public var description: String {
        var text = "TypeSafe API error \(status) (\(kind))"
        if let message { text += ": \(message)" }
        if let requestID { text += " [request \(requestID)]" }
        return text
    }
}

extension TypeSafeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingAPIKey:
            "No API key. Pass apiKey: to TypeSafeClient or set TYPESAFE_API_KEY."
        case .invalidRequest(let reason):
            "Invalid request: \(reason)"
        case .api(let error):
            error.description
        case .connection(let underlying):
            "Connection failed: \(underlying)"
        case .timeout(let seconds):
            "Request timed out after \(seconds)s"
        case .decoding(let underlying, _):
            "Could not decode response: \(underlying)"
        case .answerMissing(let id):
            "No answer for question \"\(id)\""
        case .answerTypeMismatch(let id, let expected, let actual):
            "Answer \"\(id)\" is a \(actual), not a \(expected)"
        }
    }
}

extension TypeSafeError: LocalizedError {
    public var errorDescription: String? { description }
}

extension APIError: LocalizedError {
    public var errorDescription: String? { description }
}
