import Foundation
import Sentry
import Testing
@testable import TokenTickTelemetry

struct TokenTickTelemetryTests {
    @Test func rateLimiterSeparatesErrorsAndAllowsRetryAfterWindow() {
        var limiter = EventRateLimiter()
        let first = limiter.accept(["cache.write", "7"], now: 100)
        #expect(first)
        let duplicate = limiter.accept(["cache.write", "7"], now: 399)
        #expect(!duplicate)
        let separate = limiter.accept(["cache.write", "8"], now: 399)
        #expect(separate)
        let retry = limiter.accept(["cache.write", "7"], now: 400)
        #expect(retry)
        for index in 0..<300 {
            let accepted = limiter.accept(["query", String(index)], now: 401)
            #expect(accepted)
        }
        let recent = limiter.accept(["query", "299"], now: 402)
        #expect(!recent)
    }

    @Test func syncIssuesKeepReasonsAndSeparateFailures() {
        let missing = AppTelemetry.sanitize(AppTelemetry.syncIssueEvent(operation: "api.executable",
            reason: "missing_executable", errorType: "CodexAPIError", code: 1))
        let rpc = AppTelemetry.syncIssueEvent(operation: "api.daily_usage", reason: "rpc_error",
            errorType: "CodexAPIError", code: -32601)
        #expect(missing.tags?["reason"] == "missing_executable")
        #expect(missing.message?.formatted.contains("missing_executable") == true)
        #expect(rpc.tags?["error_code"] == "-32601")
        #expect(missing.fingerprint != rpc.fingerprint)
    }

    @Test func errorDetailsKeepContextWithoutChangingGrouping() {
        let first = AppTelemetry.syncIssueEvent(operation: "api.daily_usage", reason: "rpc_error", errorType: "CodexAPIError", code: -32603,
            rpcMethod: "account/usage/read", durationMilliseconds: 123, errorMessage: "HTTP 503 at /tmp/cache: Authorization: Bearer abc.def.ghi")
        let second = AppTelemetry.syncIssueEvent(operation: "api.daily_usage", reason: "rpc_error", errorType: "CodexAPIError", code: -32603,
            durationMilliseconds: 900, errorMessage: "Another failure")
        let event = AppTelemetry.sanitize(first)
        #expect(event.fingerprint == second.fingerprint)
        #expect(event.tags?["rpc_method"] == "account/usage/read")
        #expect(event.context?["rpc"]?["duration_ms"] as? Int == 123)
        let payload = String(describing: event.serialize())
        #expect(payload.contains("HTTP 503 at /tmp/cache"))
        #expect(!payload.contains("abc.def.ghi"))
        let scrubbed = AppTelemetry.scrubErrorMessage(#"{"refresh_token":"sensitive", "api_key":"another"} https://user:pass@example.com password=hunter2"#)
        for secret in ["sensitive", "another", "user:pass", "hunter2"] { #expect(!scrubbed.contains(secret)) }
        #expect(AppTelemetry.scrubErrorMessage(String(repeating: "a", count: 3000)).count == 2048)
    }

    @Test func cancellationIsNotAnError() {
        #expect(AppTelemetry.errorEvent(CancellationError(), operation: "sync") == nil)
        #expect(AppTelemetry.errorEvent(URLError(.cancelled), operation: "sync") == nil)
    }

    @Test func handledErrorsRetainDescriptionsWithoutArbitraryUserInfo() throws {
        let error = NSError(domain: "private-account@example.com", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Failed to open /Users/private/usage.sqlite: password=credential-value",
            NSUnderlyingErrorKey: NSError(domain: "secret", code: 2)
        ])
        let event = try #require(AppTelemetry.errorEvent(error, operation: "database.open"))
        let payload = String(describing: event.serialize())
        #expect(payload.contains("/Users/private/usage.sqlite"))
        #expect(!payload.contains("credential-value"))
        #expect(!payload.contains("private-account@example.com"))
        #expect(!payload.contains("SQL"))
        #expect(event.tags?["error_code"] == "7")
        #expect(event.fingerprint?.first == "database.open")
    }

    @Test func scrubKeepsAnonymousIdentityAndRemovesSensitiveContext() {
        let event = Event(level: .fatal)
        let user = User(userId: "anonymous-installation")
        user.email = "private@example.com"
        user.ipAddress = "127.0.0.1"
        event.user = user
        event.extra = ["sql": "private query"]
        event.context = ["user info": ["secret": "token"], "device": ["name": "Private Mac", "arch": "arm64"]]
        event.message = SentryMessage(formatted: "private exception reason")
        event.exceptions = [Exception(value: "private path", type: "NSException")]
        let sanitized = AppTelemetry.sanitize(event)
        #expect(sanitized.user?.userId == "anonymous-installation")
        #expect(sanitized.user?.email == nil)
        #expect(sanitized.user?.ipAddress == nil)
        #expect(sanitized.extra == nil)
        #expect(sanitized.message == nil)
        #expect(sanitized.context?["user info"] == nil)
        #expect(sanitized.context?["device"]?["name"] == nil)
        #expect(sanitized.context?["device"]?["arch"] as? String == "arm64")
        #expect(sanitized.exceptions?.first?.value == "Exception details omitted")
    }

    @Test func wrappedDownloadFailureKeepsSafeNetworkCause() throws {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "Request timed out: token=private-token https://user:password@github.com/appcast.xml?signature=private-signature#private-fragment",
            NSLocalizedFailureReasonErrorKey: "Unable to fetch update metadata",
            NSURLErrorFailingURLErrorKey: URL(string: "https://user:password@github.com/yeliex/tokentick/appcast.xml?signature=private-signature#private-fragment")!,
            "response": "private-response-body"
        ])
        let error = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [
            NSLocalizedDescriptionKey: "An error occurred while downloading the update.",
            NSUnderlyingErrorKey: underlying
        ])
        let event = AppTelemetry.sanitize(try #require(AppTelemetry.errorEvent(error, operation: "update.download")))
        let causes = try #require(event.context?["error_details"]?["causes"] as? [[String: Any]])
        #expect(causes.count == 2)
        #expect(causes[0]["domain"] as? String == "SUSparkleErrorDomain")
        #expect(causes[1]["domain"] as? String == NSURLErrorDomain)
        #expect(causes[1]["code"] as? Int == NSURLErrorTimedOut)
        #expect(causes[1]["failure_reason"] as? String == "Unable to fetch update metadata")
        #expect(causes[1]["url"] as? String == "https://github.com/yeliex/tokentick/appcast.xml")
        let other = try #require(AppTelemetry.errorEvent(NSError(domain: "SUSparkleErrorDomain", code: 2001), operation: "update.download"))
        #expect(event.fingerprint == other.fingerprint)
        let payload = String(describing: event.serialize())
        for secret in ["private-token", "private-signature", "private-fragment", "private-response-body", "user:password"] {
            #expect(!payload.contains(secret))
        }
    }

    @Test func errorCauseChainIsBounded() throws {
        var error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        for _ in 0..<10 {
            error = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: error,
                NSLocalizedDescriptionKey: String(repeating: "a", count: 3000)])
        }
        let event = try #require(AppTelemetry.errorEvent(error, operation: "update.download"))
        let causes = try #require(event.context?["error_details"]?["causes"] as? [[String: Any]])
        #expect(causes.count == 4)
        #expect(causes.allSatisfy { ($0["message"] as? String)?.count == 2048 })
    }

    @Test func releaseUsesInstalledBundleVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.TokenTick",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42"
        ], format: .xml, options: 0)
        try plist.write(to: directory.appendingPathComponent("Info.plist"))
        let options = Options()
        AppTelemetry.configure(options, bundle: try #require(Bundle(url: directory)))
        #expect(options.releaseName == "com.example.TokenTick@1.2.3+42")
        #expect(options.dist == "42")
    }

    @Test func optionsEnableSessionsWithoutContentCollection() {
        let options = Options()
        AppTelemetry.configure(options, bundle: .main)
        #expect(options.enableAutoSessionTracking)
        #expect(!options.sendDefaultPii)
        #expect(!options.enableAutoBreadcrumbTracking)
        #expect(!options.enableNetworkBreadcrumbs)
        #expect(!options.enableCaptureFailedRequests)
        #expect(!options.enableAppHangTracking)
        #expect(options.tracesSampleRate == nil)
        #expect(options.releaseName?.contains("@") == true)
    }
}
