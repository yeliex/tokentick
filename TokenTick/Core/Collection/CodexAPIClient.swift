import Darwin
import Foundation

/// Read statistics through the installed Codex stdio protocol and let Codex manage authentication.
public struct CodexAPIClient: Sendable {
    private let executable: URL
    private let codexHome: URL

    private init(executable: URL? = nil, codexHome: URL = LocalUsageScanner.defaultCodexHome) throws {
        let candidates = executable.map { [$0.path] } ??
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
            + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexAPIError.missingExecutable
        }
        self.executable = URL(fileURLWithPath: path)
        self.codexHome = codexHome
    }

    public static func synchronize(store: UsageStore, executable: URL? = nil,
                                   codexHome: URL = LocalUsageScanner.defaultCodexHome,
                                   onCurrentLimits: (@Sendable (CurrentLimitSnapshot?) async -> Void)? = nil,
                                   onFailure: (@Sendable () async -> Void)? = nil) async throws -> APISyncReport {
        let task = Task.detached(priority: .utility) {
            do {
                let client = try Self(executable: executable, codexHome: codexHome)
                let session = try CodexAPISession(executable: client.executable, codexHome: client.codexHome)
                defer { session.close() }
                let before: CodexRateLimits = try session.request("account/rateLimits/read")
                var daily: CodexDailyUsage?
                var issue: String?
                do {
                    daily = try session.request("account/usage/read")
                }
                catch let error as CodexAPIError { issue = error.localizedDescription }
                // Email is display-only; failure to fetch it must not block limit or usage synchronization.
                let account: CodexAccountResponse? = try? session.request("account/read", params: ["refreshToken": false])
                // Bracket accountless daily buckets with account-bearing observations to detect login changes.
                let after: CodexRateLimits = try session.request("account/rateLimits/read")
                if before.accountId != after.accountId {
                    daily = nil
                    issue = String(localized: "The account changed during the request. These daily buckets were discarded.", bundle: .module)
                }
                try Task.checkCancellation()
                let observedAt = Date()
                let report = try UsageStore.prepareAPIObservation(limits: after, daily: daily, observedAt: observedAt, issue: issue,
                                                    limitsSourceJSON: session.lastResponseJSON,
                                                    accountEmail: account?.subscriptionEmail(before: before, after: after))
                // Display validated limits before waiting for the log scanner's database write lock.
                await onCurrentLimits?(report.currentLimits)
                try Task.checkCancellation()
                try store.saveAPIObservation(report, daily: daily, observedAt: observedAt)
                return report
            } catch {
                try Task.checkCancellation()
                await onFailure?()
                try store.saveAPIFailure(error.localizedDescription)
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

enum CodexAPIError: Error, LocalizedError {
    case missingExecutable, timeout, processExited, invalidResponse, oversizedResponse, rpc(Int), invalidStatistics
    var errorDescription: String? {
        switch self {
        case .missingExecutable: String(localized: "Codex CLI executable not found. Specify the codex path.", bundle: .module)
        case .timeout: String(localized: "The Codex statistics request timed out.", bundle: .module)
        case .processExited: String(localized: "Codex app-server exited before statistics were loaded.", bundle: .module)
        case .invalidResponse: String(localized: "Codex app-server returned an unrecognized protocol response.", bundle: .module)
        case .oversizedResponse: String(localized: "The Codex statistics response exceeds the 4 MiB limit.", bundle: .module)
        case .rpc(let code): String(localized: "The Codex statistics API returned error \(code). Existing history was kept.", bundle: .module)
        case .invalidStatistics: String(localized: "Codex statistics contain invalid dates, duplicate daily buckets, or invalid values. No data was written.", bundle: .module)
        }
    }
}

/// Use within one background task; no persistent daemon and no reading or copying auth.json.
final class CodexAPISession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private let timeout: TimeInterval
    private(set) var lastResponseJSON: String?

    init(executable: URL, codexHome: URL, timeout: TimeInterval = 30) throws {
        self.timeout = timeout
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": codexHome.path]) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        do {
            let _: EmptyResult = try request("initialize", params: [
                "clientInfo": ["name": "tokentick", "version": ApplicationInfo.version],
                "capabilities": ["experimentalApi": true]
            ])
            try write(["method": "initialized"])
        } catch { close(); throw error }
    }

    deinit { close() }

    func close() {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            // An unresponsive child process must not block app exit or synchronization cancellation.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }

    func request<Result: Decodable>(_ method: String, params: [String: Any] = [:]) throws -> Result {
        lastResponseJSON = nil
        nextID += 1
        try write(["id": nextID, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let header = try? JSONDecoder().decode(Header.self, from: line) else { throw CodexAPIError.invalidResponse }
                guard header.id == nextID else { continue }
                if let error = header.error { throw CodexAPIError.rpc(error.code) }
                guard let response = try? JSONDecoder().decode(Response<Result>.self, from: line) else { throw CodexAPIError.invalidResponse }
                guard let envelope = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let result = envelope["result"] else { throw CodexAPIError.invalidResponse }
                lastResponseJSON = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
                return response.result
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw CodexAPIError.processExited }
            guard ready > 0 else { continue }
            // NSFileHandle waits to fill the buffer; use a single pipe read to respect RPC timeouts.
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexAPIError.processExited }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 4 * 1_024 * 1_024 else { throw CodexAPIError.oversizedResponse }
        }
        throw CodexAPIError.timeout
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private struct EmptyResult: Decodable {}
    private struct Header: Decodable {
        let id: Int?
        let error: RPCError?
        struct RPCError: Decodable { let code: Int }
    }
    private struct Response<Result: Decodable>: Decodable { let result: Result }
}
