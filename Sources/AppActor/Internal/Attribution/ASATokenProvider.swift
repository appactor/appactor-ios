import Foundation

// MARK: - Token Result

/// Result of attempting to fetch an ASA attribution token.
enum AppActorASATokenResult: Sendable {
    /// Token obtained successfully.
    case token(String)
    /// Platform doesn't support AdServices (macOS, watchOS, iOS < 14.3).
    /// Attribution should be marked as completed (organic).
    case unavailable
    /// Transient error (AdServices framework failure).
    /// Attribution should NOT be marked as completed — retry on next launch.
    case error(Error)
}

/// Result of calling Apple's AdServices attribution API.
/// The raw JSON dictionary is wrapped as `@unchecked Sendable` because
/// `[String: Any]` from JSONSerialization is effectively immutable after creation.
struct AppActorASAAppleAttributionResponse: @unchecked Sendable {
    let json: [String: Any]
}

enum AppActorASAAppleAttributionResult: Sendable {
    /// Apple returned attribution data successfully.
    case success(AppActorASAAppleAttributionResponse)
    /// Apple API call failed (transient — retry later).
    case error(Error)
}

// MARK: - Protocol

/// Abstraction over `AAAttribution.attributionToken()` and Apple's AdServices API for testability.
///
/// The live implementation uses AdServices framework (iOS 14.3+).
/// Returns `.unavailable` on unsupported platforms (macOS, watchOS, etc.).
protocol AppActorASATokenProviderProtocol: Sendable {
    /// Returns the ASA attribution token result.
    func attributionToken() async -> AppActorASATokenResult
    /// Calls Apple's `api-adservices.apple.com/api/v1/` with the given token
    /// to obtain the raw attribution response.
    func fetchAppleAttribution(token: String) async -> AppActorASAAppleAttributionResult
}

// MARK: - Live Implementation

/// Production token provider using Apple's AdServices framework.
///
/// - iOS 14.3+: calls `AAAttribution.attributionToken()`
/// - All other platforms: returns `.unavailable`
final class AppActorASALiveTokenProvider: AppActorASATokenProviderProtocol, Sendable {

    /// Maximum number of token fetch attempts before returning error.
    private static let maxRetries = 3
    /// Delay between retry attempts (seconds).
    private static let retryDelay: UInt64 = 3_000_000_000 // 3s in nanoseconds
    /// Maximum number of Apple API call attempts.
    private static let maxAppleAPIRetries = 3
    /// Delay between Apple API retry attempts (seconds).
    private static let appleAPIRetryDelay: UInt64 = 5_000_000_000 // 5s in nanoseconds

    func attributionToken() async -> AppActorASATokenResult {
        #if targetEnvironment(simulator)
        // Simulator doesn't support AdServices at runtime — return immediately
        // instead of burning 6+ seconds on futile retries.
        Log.attribution.debug("Simulator detected, skipping attribution token fetch")
        return .unavailable
        #elseif canImport(AdServices) && os(iOS)
        if #available(iOS 14.3, *) {
            var lastError: Error?
            for attempt in 1...Self.maxRetries {
                do {
                    let token = try AAAttribution.attributionToken()
                    return .token(token)
                } catch {
                    lastError = error
                    if attempt < Self.maxRetries {
                        Log.attribution.warn("Token fetch attempt \(attempt)/\(Self.maxRetries) failed: \(error.localizedDescription), retrying in 3s…")
                        do {
                            try await Task.sleep(nanoseconds: Self.retryDelay)
                        } catch {
                            // [Fix #5] Return the sleep cancellation error itself, not the
                            // previous token-fetch error. `lastError` is always non-nil here
                            // (set on L71), so `lastError ?? error` would mask the CancellationError.
                            Log.attribution.debug("Token retry cancelled during sleep")
                            return .error(error)
                        }
                    }
                }
            }
            guard let finalError = lastError else {
                return .error(NSError(domain: "AppActorASA", code: -1, userInfo: [NSLocalizedDescriptionKey: "Token fetch failed with unknown error"]))
            }
            Log.attribution.warn("Failed to get attribution token after \(Self.maxRetries) attempts: \(finalError.localizedDescription)")
            return .error(finalError)
        } else {
            Log.attribution.debug("AdServices requires iOS 14.3+, skipping attribution")
            return .unavailable
        }
        #else
        Log.attribution.debug("AdServices not available on this platform, skipping attribution")
        return .unavailable
        #endif
    }

    func fetchAppleAttribution(token: String) async -> AppActorASAAppleAttributionResult {
        let url = URL(string: "https://api-adservices.apple.com/api/v1/")!

        var lastError: Error?
        for attempt in 1...Self.maxAppleAPIRetries {
            // Check cancellation before each attempt
            guard !Task.isCancelled else {
                Log.attribution.debug("Apple API call cancelled")
                return .error(CancellationError())
            }

            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(token.utf8)

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    Log.attribution.warn("Apple API attempt \(attempt)/\(Self.maxAppleAPIRetries): invalid response type")
                    lastError = NSError(domain: "AppActorASA", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response type from Apple AdServices API"])
                    if attempt < Self.maxAppleAPIRetries {
                        try await Task.sleep(nanoseconds: Self.appleAPIRetryDelay)
                    }
                    continue
                }

                // 4xx (except 429) — permanent client error, don't retry
                let status = httpResponse.statusCode
                if (400..<500).contains(status) && status != 429 {
                    Log.attribution.warn("Apple API returned permanent error HTTP \(status), not retrying")
                    return .error(NSError(domain: "AppActorASA", code: status, userInfo: [NSLocalizedDescriptionKey: "Apple AdServices API returned HTTP \(status)"]))
                }

                guard status == 200 else {
                    lastError = NSError(domain: "AppActorASA", code: status, userInfo: [NSLocalizedDescriptionKey: "Apple AdServices API returned HTTP \(status)"])
                    if attempt < Self.maxAppleAPIRetries {
                        Log.attribution.warn("Apple API attempt \(attempt)/\(Self.maxAppleAPIRetries) returned \(status), retrying in 5s…")
                        try await Task.sleep(nanoseconds: Self.appleAPIRetryDelay)
                    }
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .error(NSError(domain: "AppActorASA", code: -3, userInfo: [NSLocalizedDescriptionKey: "Apple AdServices API response is not valid JSON"]))
                }

                Log.attribution.debug("Apple AdServices API returned attribution data")
                return .success(AppActorASAAppleAttributionResponse(json: json))

            } catch is CancellationError {
                Log.attribution.debug("Apple API call cancelled")
                return .error(CancellationError())
            } catch let urlError as URLError where urlError.code == .cancelled {
                // [Fix #6] URLSession throws URLError(.cancelled) — not CancellationError —
                // when the underlying task is cancelled. Without this catch, it falls into
                // the generic handler below and triggers a retry instead of stopping.
                Log.attribution.debug("Apple API call cancelled (URLError)")
                return .error(CancellationError())
            } catch {
                lastError = error
                if attempt < Self.maxAppleAPIRetries {
                    Log.attribution.warn("Apple API attempt \(attempt)/\(Self.maxAppleAPIRetries) failed: \(error.localizedDescription), retrying in 5s…")
                    do {
                        try await Task.sleep(nanoseconds: Self.appleAPIRetryDelay)
                    } catch {
                        // Sleep cancelled — propagate cancellation
                        Log.attribution.debug("Apple API retry sleep cancelled")
                        return .error(error)
                    }
                }
            }
        }

        let finalError = lastError ?? NSError(domain: "AppActorASA", code: -4, userInfo: [NSLocalizedDescriptionKey: "Apple AdServices API failed after \(Self.maxAppleAPIRetries) attempts"])
        Log.attribution.warn("Apple AdServices API failed after \(Self.maxAppleAPIRetries) attempts: \(finalError.localizedDescription)")
        return .error(finalError)
    }
}

// MARK: - AdServices Import

#if canImport(AdServices) && os(iOS)
import AdServices
#endif
