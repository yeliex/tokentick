import Darwin
import Foundation

/// Share one login-shell snapshot across SSH connections for the lifetime of the app.
actor LoginShellEnvironment {
    static let shared = LoginShellEnvironment()
    private var snapshot: Task<[String: String], Error>?

    func values() async throws -> [String: String] {
        if snapshot == nil {
            snapshot = Task {
                let inherited = ProcessInfo.processInfo.environment
                let shell = inherited["SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
                return try await Self.read(shell: shell, inherited: inherited)
            }
        }
        let values = try await snapshot!.value
        try Task.checkCancellation()
        return values
    }

    static func read(shell: String, inherited: [String: String], timeout: TimeInterval = 10) async throws -> [String: String] {
        let marker = UUID().uuidString
        // NUL framing excludes startup/exit messages and preserves multiline exported values.
        let command = "printf '\\000\(marker)\\000'; /usr/bin/env -0; printf '\\000\(marker)\\000'"
        let result = try await DeviceCommand.run(executable: URL(fileURLWithPath: shell),
            arguments: ["-ilc", command], environment: inherited, timeout: timeout, outputLimit: 1_048_576)
        let delimiter = Data(("\0" + marker + "\0").utf8)
        guard result.status == 0, let start = result.output.range(of: delimiter),
              let end = result.output.range(of: delimiter, in: start.upperBound..<result.output.endIndex) else {
            throw DeviceCommand.Failure.io
        }
        var environment: [String: String] = [:]
        for entry in result.output[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let separator = entry.firstIndex(of: 61), separator != entry.startIndex,
                  let key = String(data: Data(entry[..<separator]), encoding: .utf8),
                  let value = String(data: Data(entry[entry.index(after: separator)...]), encoding: .utf8) else {
                throw DeviceCommand.Failure.io
            }
            environment[key] = value
        }
        return environment
    }
}
