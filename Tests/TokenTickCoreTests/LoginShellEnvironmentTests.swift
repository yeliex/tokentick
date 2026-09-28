import Foundation
import Testing
@testable import TokenTickCore

struct LoginShellEnvironmentTests {
    @Test func readsLoginAndInteractiveExportsWithoutStartupOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export TOKENTICK_TEST_LOGIN=profile\nprintf 'Welcome!\\n'\n".write(to: root.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try "export TOKENTICK_TEST_VALUE='first=second\nthird'\nexport PATH=/fixture/bin:$PATH\nunset TOKENTICK_TEST_REMOVED\n".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let values = try await LoginShellEnvironment.read(shell: "/bin/zsh", inherited: [
            "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin", "TOKENTICK_TEST_REMOVED": "old"
        ])
        #expect(values["TOKENTICK_TEST_LOGIN"] == "profile")
        #expect(values["TOKENTICK_TEST_VALUE"] == "first=second\nthird")
        #expect(values["PATH"]?.hasPrefix("/fixture/bin:") == true)
        #expect(values["TOKENTICK_TEST_REMOVED"] == nil)
        #expect(values["Welcome!"] == nil)
    }

    @Test func stalledStartupTimesOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "while true; do :; done\n".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        await #expect(throws: DeviceCommand.Failure.timeout) {
            _ = try await LoginShellEnvironment.read(shell: "/bin/zsh", inherited: ["ZDOTDIR": root.path], timeout: 0.2)
        }
    }
}
