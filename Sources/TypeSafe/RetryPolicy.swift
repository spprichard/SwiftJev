import Foundation

/// When and how to retry a failed attempt. The defaults match the official SDKs.
public struct RetryPolicy: Sendable, Hashable {
    /// Retries after the initial attempt; `0` disables retries.
    public var maxRetries: Int = 2

    /// First backoff delay, doubled each retry up to `backoffMax`.
    public var backoffInitial: Duration = .milliseconds(500)

    /// Longest backoff delay.
    public var backoffMax: Duration = .seconds(5)

    /// Fraction of each backoff delay randomly subtracted, from 0 to 1.
    public var backoffJitter: Double = 0.25

    /// HTTP statuses to retry. 529 (overloaded) is covered by the 5xx range.
    public var httpStatuses: Set<Int> = Set([408, 429]).union(500...599)

    /// Honor `Retry-After` and `retry-after-ms` response headers.
    public var respectRetryAfter: Bool = true

    /// Longest server-requested delay to honor; longer ones fall back to backoff.
    public var maxRetryAfter: Duration = .seconds(60)

    /// Retry ``TypeSafeError/connection(underlying:)``.
    public var retryConnectionErrors: Bool = true

    /// Retry ``TypeSafeError/timeout(_:)``.
    public var retryTimeouts: Bool = true

    public init() {}

    public static let `default` = RetryPolicy()

    /// A policy that never retries.
    public static var noRetries: RetryPolicy {
        var policy = RetryPolicy()
        policy.maxRetries = 0
        return policy
    }

    /// The delay before retry number `attempt` (0-based), before jitter.
    func backoff(attempt: Int) -> Duration {
        let initial = backoffInitial.seconds
        let capped = min(initial * pow(2, Double(attempt)), backoffMax.seconds)
        let jitter = Double.random(in: 0...max(0, min(1, backoffJitter))) * capped
        return .seconds(max(0, capped - jitter))
    }

    /// The delay to use for a retryable response: the server's request when it
    /// is present and within `maxRetryAfter`, else backoff.
    func delay(attempt: Int, retryAfter: Duration?) -> Duration {
        if respectRetryAfter, let retryAfter, retryAfter <= maxRetryAfter {
            return retryAfter
        }
        return backoff(attempt: attempt)
    }
}

/// Per-call overrides for ``TypeSafeClient`` settings.
public struct RequestOptions: Sendable {
    /// Extra headers, merged over the client's default headers.
    public var headers: [String: String] = [:]

    /// Per-attempt timeout for this call.
    public var timeout: Duration?

    /// Retry policy for this call.
    public var retryPolicy: RetryPolicy?

    public init(headers: [String: String] = [:], timeout: Duration? = nil, retryPolicy: RetryPolicy? = nil) {
        self.headers = headers
        self.timeout = timeout
        self.retryPolicy = retryPolicy
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
