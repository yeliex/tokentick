import Foundation
import Testing
@testable import TokenTickCore

struct DeviceAccountIdentityTests {
    @Test func loginUsesSelectedHomeAndCodexProtocol() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'"method":"account/rateLimits/read"'*)
              [ -d "$CODEX_HOME" ] || exit 1
              printf '%s\n' '{"id":2,"result":{"accountId":"source-account","rateLimits":{}}}' ;;
            *'"method":"account/read"'*) printf '%s\n' '{"id":3,"result":{"account":{"type":"chatgpt","email":"member@example.invalid"}}}' ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = try CodexAPISession(executable: executable, codexHome: root)
        defer { session.close() }
        let account = try DeviceAccount.read(session: session)
        #expect(account.id == "source-account")
        #expect(account.email == "member@example.invalid")
    }
}
