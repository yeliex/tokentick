import Foundation
import Sentry
import Synchronization

public enum AppTelemetry {
    private static let limiter = Mutex(EventRateLimiter())
    public static func start() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        SentrySDK.start { options in
            configure(options, bundle: .main)
        }
    }

    static func configure(_ options: Options, bundle: Bundle) {
        options.dsn = "https://0479bb2dfde727629d95d23b2b9c82d8@o51212.ingest.us.sentry.io/4512093648650240"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        options.releaseName = "\(bundle.bundleIdentifier ?? "TokenTick")@\(version)+\(build)"
        options.dist = build
        #if DEBUG
        options.environment = "development"
        #else
        options.environment = "production"
        #endif
        options.debug = false
        options.sendDefaultPii = false
        // Release Health counts the SDK's anonymous installation ID, including error-free sessions.
        options.enableAutoSessionTracking = true
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableNetworkTracking = false
        options.enableSwizzling = false
        // A menu-bar process can remain inactive or asleep for long periods.
        options.enableAppHangTracking = false
        options.beforeSend = { event in sanitize(event) }
    }

    public static func capture(_ error: any Error, operation: StaticString, warning: Bool = false) {
        guard let event = errorEvent(error, operation: operation) else { return }
        if warning { event.level = .warning }
        submit(event)
    }

    public static func captureIssue(operation: String, reason: String, errorType: String? = nil, code: Int? = nil, count: Int? = nil, warning: Bool = false, rpcMethod: String? = nil, durationMilliseconds: Int? = nil, decodingFailure: String? = nil, errorMessage: String? = nil) {
        let event = syncIssueEvent(operation: operation, reason: reason, errorType: errorType, code: code, rpcMethod: rpcMethod, durationMilliseconds: durationMilliseconds, decodingFailure: decodingFailure, errorMessage: errorMessage)
        if warning { event.level = .warning }
        if let count { event.tags?["issue_count"] = String(count) }
        submit(event)
    }

    private static func submit(_ event: Event) {
        guard limiter.withLock({ $0.accept(event.fingerprint ?? [], now: ProcessInfo.processInfo.systemUptime) }) else { return }
        SentrySDK.capture(event: event)
    }

    static func syncIssueEvent(operation: String, reason: String, errorType: String?, code: Int?, rpcMethod: String? = nil, durationMilliseconds: Int? = nil, decodingFailure: String? = nil, errorMessage: String? = nil) -> Event {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "\(operation) failed: \(reason)" + (code.map { " (code \($0))" } ?? ""))
        event.fingerprint = [operation, reason, errorType ?? "none", code.map(String.init) ?? "none"]
        event.tags = ["operation": operation, "reason": reason]
        event.tags?["error_type"] = errorType
        event.tags?["error_code"] = code.map(String.init)
        event.tags?["rpc_method"] = rpcMethod
        event.tags?["decoding_failure"] = decodingFailure
        if let durationMilliseconds {
            event.context = ["rpc": ["duration_ms": durationMilliseconds]]
        }
        if let errorMessage {
            event.context = (event.context ?? [:]).merging(["error_details": ["message": scrubErrorMessage(errorMessage)]]) { _, new in new }
        }
        return event
    }

    static func errorEvent(_ error: any Error, operation: StaticString) -> Event? {
        let nsError = error as NSError
        guard !(error is CancellationError),
              !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return nil }
        // Preserve actionable descriptions without attaching arbitrary userInfo or underlying response bodies.
        let type = String(reflecting: type(of: error))
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "\(operation) failed (\(type), code \(nsError.code))")
        event.context = ["error_details": ["message": scrubErrorMessage(error.localizedDescription)]]
        event.fingerprint = [String(describing: operation), type, String(nsError.code)]
        event.tags = ["operation": String(describing: operation), "error_type": type, "error_code": String(nsError.code)]
        return event
    }

    /// Keep paths and diagnostic text, but redact common credential assignments and authorization values.
    static func scrubErrorMessage(_ message: String) -> String {
        var result = message
        let patterns = [
            #"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(["']?(?:access[_-]?token|refresh[_-]?token|id[_-]?token|token|api[_-]?key|password|secret|authorization|cookie)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;&}]+)"#,
            #"\b(?:sk-|sk_)[A-Za-z0-9_-]{16,}"#,
            #"(https?://)[^\s/@:]+:[^\s/@]+@"#
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: index == 1 || index == 3 ? "$1[REDACTED]" : "[REDACTED]")
        }
        return String(result.prefix(2_048))
    }

    static func sanitize(_ event: Event) -> Event {
        event.request = nil
        event.extra = nil
        event.breadcrumbs = nil
        if let id = event.user?.userId {
            event.user = User(userId: id)
        } else {
            event.user = nil
        }
        event.context?.removeValue(forKey: "user info")
        event.context?["device"]?.removeValue(forKey: "name")
        // Native exception reasons can embed user-provided values; retain types and stack traces.
        if let exceptions = event.exceptions, !exceptions.isEmpty {
            event.message = nil
            for exception in exceptions { exception.value = "Exception details omitted" }
        }
        return event
    }
}

/// Bound both event volume and memory without suppressing unrelated failures or native crashes.
struct EventRateLimiter {
    private var sent: [[String]: TimeInterval] = [:]

    mutating func accept(_ fingerprint: [String], now: TimeInterval) -> Bool {
        sent = sent.filter { now - $0.value < 300 }
        guard sent[fingerprint] == nil else { return false }
        if sent.count >= 256, let oldest = sent.min(by: { $0.value < $1.value })?.key {
            sent.removeValue(forKey: oldest)
        }
        sent[fingerprint] = now
        return true
    }
}
