import Foundation

/// Retry behavior for provider calls, mirroring SophonCore's
/// `LLMRetryPolicy.default`: 3 attempts total, 0.8s base delay doubling to a
/// 6s cap, `Retry-After` honored, 0–20% jitter, and no retry when the server
/// asks for a wait longer than the cap.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var honorsRetryAfter: Bool
    public var usesJitter: Bool
    public var stopsWhenServerDelayExceedsMaxDelay: Bool

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.8,
        maxDelay: TimeInterval = 6.0,
        honorsRetryAfter: Bool = true,
        usesJitter: Bool = true,
        stopsWhenServerDelayExceedsMaxDelay: Bool = true
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.honorsRetryAfter = honorsRetryAfter
        self.usesJitter = usesJitter
        self.stopsWhenServerDelayExceedsMaxDelay = stopsWhenServerDelayExceedsMaxDelay
    }

    public static let `default` = RetryPolicy()

    /// Whether a server asking for `serverDelay` seconds ends the call under
    /// this policy instead of being retried.
    public func stops(forServerDelay serverDelay: TimeInterval?) -> Bool {
        guard honorsRetryAfter, stopsWhenServerDelayExceedsMaxDelay, let serverDelay, serverDelay.isFinite else { return false }
        return serverDelay > maxDelay
    }

    /// Backoff for the `retry`-th retry (1-based). Honors a server
    /// `Retry-After` (already parsed to seconds) when enabled; otherwise
    /// exponential backoff capped at `maxDelay`, with optional jitter.
    public func backoffDelay(retry: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if honorsRetryAfter, let retryAfter, retryAfter.isFinite {
            return min(max(0, retryAfter), maxDelay)
        }
        let exponential = baseDelay * pow(2.0, Double(max(1, retry) - 1))
        guard !exponential.isNaN else { return 0 }
        let capped = min(exponential, maxDelay)
        guard usesJitter else { return capped }
        let jitter = capped * Double.random(in: 0 ... 0.2)
        return capped + jitter <= maxDelay ? capped + jitter : capped - jitter
    }
}

/// Classifies a failed call for retry: whether it may be retried at all, and
/// the server-named wait (from `Retry-After`) when one was attached.
public enum RetryClassifier {
    public struct Decision: Sendable, Equatable {
        public var isRetryable: Bool
        public var retryAfter: TimeInterval?
    }

    public static func decision(for error: Error) -> Decision {
        guard let providerError = error as? LLMProviderError else {
            return Decision(isRetryable: false, retryAfter: nil)
        }
        switch providerError {
        case .timeout, .connectionLost:
            return Decision(isRetryable: true, retryAfter: nil)
        case .invalidStatus(let code, _, let retryAfter):
            let retryable = code == 429 || (500..<600).contains(code)
            return Decision(isRetryable: retryable, retryAfter: retryAfter)
        case .missingAPIKey, .invalidURL, .malformedJSON, .emptyOutput:
            return Decision(isRetryable: false, retryAfter: nil)
        }
    }
}

/// Helpers for reading a server-named wait off an HTTP response.
public enum RetrySupport {
    /// Parses a `Retry-After` header (seconds, or an HTTP date) into a wait
    /// in seconds. Returns nil when the header is absent or unparsable.
    public static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = Double(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
