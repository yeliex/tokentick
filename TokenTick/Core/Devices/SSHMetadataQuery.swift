import Foundation

/// Fixed source projections over system SSH; source content never becomes command text.
struct SSHMetadataQuery: Sendable {
    enum Shell: Sendable { case posix, powershell, commandPrompt }
    struct Request: Encodable {
        let operation: String
        let root: String?
        var after: String? = nil
        var includeDesktop = true
        var file: String? = nil
        var cursor: Cursor? = nil

        struct Cursor: Encodable {
            let inode: String
            let device: String
            let lastID: String
            let anchor: String?
            init(_ value: CodexFastEvidence.Cursor) {
                inode = String(value.inode); device = String(value.device)
                lastID = String(value.lastID); anchor = value.anchor
            }
        }
    }
    private struct Reply<Value: Decodable>: Decodable {
        let result: Value?
        let failure: DeviceSourceFailure?
    }
    let arguments: [String]
    let environment: [String: String]
    let command: String

    static func command(path: String, shell: Shell) throws -> String {
        guard !path.isEmpty, !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw DeviceSourceFailure.invalidPath
        }
        switch shell {
        case .posix:
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' -"
        case .powershell:
            return "& '" + path.replacingOccurrences(of: "'", with: "''") + "' -"
        case .commandPrompt:
            // cmd expands percent variables even inside quotes; never interpret a source path as one.
            guard !path.contains(where: { "%!\"".contains($0) }) else { throw DeviceSourceFailure.unsupported }
            return "\"" + path + "\" -"
        }
    }

    func accountSession(root: String) async throws -> CodexAPISession {
        let executable: String = try await read(.init(operation: "executable", root: root), as: String.self)
        // A static launcher carries the selected home as JSON; the RPC stream stays on stdin/stdout.
        let home = String(decoding: try JSONEncoder().encode(root), as: UTF8.self)
        let path = String(decoding: try JSONEncoder().encode(executable), as: UTF8.self)
        let script = """
        const executable = \(path);
        const windows = process.platform === 'win32';
        const shell = windows && executable.endsWith('.cmd');
        const child = require('node:child_process').spawn(shell ? '\"' + executable + '\"' : executable, ['app-server', '--stdio'], {
            stdio: 'inherit', env: {...process.env, CODEX_HOME: \(home)},
            shell
        });
        child.on('error', () => process.exit(1));
        child.on('exit', code => process.exit(code ?? 1));
        """
        let encoded = Data(script.utf8).base64EncodedString()
        guard command.hasSuffix(" -") else { throw DeviceSourceFailure.unsupported }
        let launcher = String(command.dropLast()) + "-e \"eval(Buffer.from('\(encoded)','base64').toString())\""
        return try CodexAPISession(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments + [launcher], environment: environment)
    }

    static func input(_ request: Request) throws -> Data {
        guard let script = Bundle.module.url(forResource: "device_query", withExtension: "js") else {
            throw DeviceSourceFailure.unsupported
        }
        var input = Data("const request = ".utf8)
        input.append(try JSONEncoder().encode(request))
        input.append(Data(";\nconst tracePageSQL = ".utf8))
        input.append(try JSONEncoder().encode(DeviceTracePage.pageSQL))
        input.append(Data(";\n".utf8))
        input.append(try Data(contentsOf: script))
        return input
    }

    func read<Value: Decodable & Sendable>(_ request: Request, as: Value.Type) async throws -> Value {
        let reply = try await DeviceCommand.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments + [command], input: Self.input(request), environment: environment,
            timeout: 60, outputLimit: 32 * 1_024 * 1_024)
        guard reply.status == 0 else { throw DeviceSourceFailure.inaccessible }
        return try Self.decode(reply.output, as: Value.self)
    }

    static func decode<Value: Decodable>(_ data: Data, as: Value.Type) throws -> Value {
        guard let reply = try? JSONDecoder().decode(Reply<Value>.self, from: data) else {
            throw DeviceSourceFailure.invalidResponse
        }
        if let failure = reply.failure { throw failure }
        guard let result = reply.result else { throw DeviceSourceFailure.invalidResponse }
        return result
    }
}
