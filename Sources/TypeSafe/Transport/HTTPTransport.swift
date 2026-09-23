import Foundation

/// An outgoing HTTP request, independent of any networking library.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    /// Time allowed for this one attempt.
    public var timeout: Duration

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: Duration) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// An HTTP response, independent of any networking library.
public struct HTTPResponse: Sendable {
    public var status: Int

    /// Header names are lowercased on init, so lookups are case-insensitive.
    public private(set) var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var requestID: String? {
        header("x-typesafe-request-id")
    }

    /// The server's requested wait, from `retry-after-ms` (milliseconds) or
    /// `Retry-After` (seconds or an HTTP date). `nil` when absent or unparseable.
    public var retryAfter: Duration? {
        if let text = header("retry-after-ms"), let milliseconds = Double(text.trimmingCharacters(in: .whitespaces)) {
            return .seconds(max(0, milliseconds / 1000))
        }
        guard let text = header("retry-after")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Double(text) {
            return .seconds(max(0, seconds))
        }
        if let date = Self.httpDateFormatter.date(from: text) {
            return .seconds(max(0, date.timeIntervalSinceNow))
        }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

/// Sends HTTP requests. ``URLSessionTransport`` is the default; implement this
/// to route through another client (AsyncHTTPClient, a proxy) or to stub the
/// API in tests.
///
/// Implementations return every HTTP response as an ``HTTPResponse``, whatever
/// its status. They throw ``TypeSafeError/timeout(_:)`` when an attempt runs
/// out of time and ``TypeSafeError/connection(underlying:)`` (or any other
/// error, which the client treats the same way) when no response arrived.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
