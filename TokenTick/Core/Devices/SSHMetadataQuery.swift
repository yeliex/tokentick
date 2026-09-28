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

    static func input(_ request: Request) throws -> Data {
        guard let script = Bundle.module.url(forResource: "device_query", withExtension: "js") else {
            throw DeviceSourceFailure.unsupported
        }
        var input = Data("const request = ".utf8)
        input.append(try JSONEncoder().encode(request))
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
