import Foundation
import Sentry

public enum AppTelemetry {
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

    public static func capture(_ error: any Error, operation: StaticString) {
        guard let event = errorEvent(error, operation: operation) else { return }
        SentrySDK.capture(event: event)
    }

    public static func captureSyncIssues(count: Int) {
        guard count > 0 else { return }
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Synchronization completed with issues")
        event.fingerprint = ["synchronization.partial"]
        event.tags = ["operation": "synchronization.partial", "issue_count": String(count)]
        SentrySDK.capture(event: event)
    }

    static func errorEvent(_ error: any Error, operation: StaticString) -> Event? {
        let nsError = error as NSError
        guard !(error is CancellationError),
              !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return nil }
        // Error descriptions/userInfo may contain SQL, local paths, account IDs, or API response bodies.
        let type = String(reflecting: type(of: error))
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "\(operation) failed (\(type), code \(nsError.code))")
        event.fingerprint = [String(describing: operation), type, String(nsError.code)]
        event.tags = ["operation": String(describing: operation), "error_type": type, "error_code": String(nsError.code)]
        return event
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
