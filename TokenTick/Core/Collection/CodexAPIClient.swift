import Darwin
import Foundation

/// 通过已安装 Codex 的 stdio 协议读取统计，让 Codex 自己管理认证。
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
                                   codexHome: URL = LocalUsageScanner.defaultCodexHome) async throws -> APISyncReport {
        let task = Task.detached(priority: .utility) {
            do {
                let client = try Self(executable: executable, codexHome: codexHome)
                let session = try CodexAPISession(executable: client.executable, codexHome: client.codexHome)
                defer { session.close() }
                let before: CodexRateLimits = try session.request("account/rateLimits/read")
                var daily: CodexDailyUsage?
                var dailySource: String?
                var issue: String?
                do {
                    daily = try session.request("account/usage/read")
                    dailySource = session.lastResponseJSON
                }
                catch let error as CodexAPIError { issue = error.localizedDescription }
                // 日桶响应没有账号字段；夹在两个自带账号的观测之间，拒绝登录切换。
                let after: CodexRateLimits = try session.request("account/rateLimits/read")
                if before.accountId != after.accountId {
                    daily = nil
                    dailySource = nil
                    issue = "读取期间账号发生切换，未保存每日桶。"
                }
                try Task.checkCancellation()
                return try store.saveAPIObservation(limits: after, daily: daily, observedAt: Date(), issue: issue,
                                                    limitsSourceJSON: session.lastResponseJSON, dailySourceJSON: dailySource)
            } catch {
                try Task.checkCancellation()
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
        case .missingExecutable: "未找到可执行的 Codex CLI，请指定 codex 路径。"
        case .timeout: "Codex 统计接口读取超时。"
        case .processExited: "Codex app-server 已退出，未完成统计读取。"
        case .invalidResponse: "Codex app-server 返回了无法识别的协议响应。"
        case .oversizedResponse: "Codex 统计响应超过 4 MiB 限制。"
        case .rpc(let code): "Codex 统计接口返回错误（\(code)）；未改写已有历史。"
        case .invalidStatistics: "Codex 统计包含非法日期、重复日桶或无效数值，未写入。"
        }
    }
}

/// 仅在一个后台任务内使用；无长期 daemon，也不读取或复制 auth.json。
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
            // 不允许失去响应的子进程拖住 App 退出或取消同步。
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
            // NSFileHandle 会继续等待填满长度；管道必须单次 read，才能遵守 RPC 超时。
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
