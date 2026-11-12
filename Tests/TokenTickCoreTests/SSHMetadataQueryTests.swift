import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct SSHMetadataQueryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"] != nil),
          arguments: ["Codex.app", "ChatGPT.app"], ["codex", "codex-cli/bin/codex"])
    func remoteMacDiscoversBundledExecutableAndReportsMissingCLI(app: String, entry: String) async throws {
        let node = try #require(ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remotePath = "/Applications/\(app)/Contents/Resources/\(entry)"
        let executable = root.appendingPathComponent(String(remotePath.dropFirst()))
        let source = String(decoding: try SSHMetadataQuery.input(.init(operation: "executable", root: root.path)), as: UTF8.self)
        let encodedSource = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        let encodedRoot = String(decoding: try JSONEncoder().encode(root.path), as: UTF8.self)
        // Model a remote Mac with an isolated application directory and no CLI on PATH.
        let script = """
        const vm = require('node:vm'), fs = require('node:fs');
        const root = \(encodedRoot);
        const mapped = p => p.startsWith('/Applications/') ? root + p : p;
        const remoteFS = {...fs,
            accessSync: (p, mode) => fs.accessSync(mapped(p), mode),
            statSync: p => fs.statSync(mapped(p))
        };
        vm.runInNewContext(\(encodedSource), {
            require: name => name === 'node:fs' ? remoteFS
                : name === 'node:os' ? {homedir: () => root + '/user'} : require(name),
            process: {platform: 'darwin', env: {PATH: root + '/bin'}, stdout: process.stdout}, Buffer, JSON
        });
        """
        func query() async throws -> String {
            let output = try await DeviceCommand.run(executable: URL(fileURLWithPath: node), arguments: ["-"], input: Data(script.utf8))
            #expect(output.status == 0)
            return try SSHMetadataQuery.decode(output.output, as: String.self)
        }
        await #expect(throws: DeviceSourceFailure.missingExecutable) { try await query() }
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        await #expect(throws: DeviceSourceFailure.missingExecutable) { try await query() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(try await query() == remotePath)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"] != nil))
    func missingRootReportsMissingDirectory() async throws {
        let node = try #require(ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: DeviceSourceFailure.missingDirectory) {
            let _: String = try await run(node, .init(operation: "root", root: root.path))
        }
    }

    @Test func commandQuotesPathsWithoutInterpolatingSourceInput() throws {
        #expect(try SSHMetadataQuery.command(path: "/home/a'b/node", shell: .posix) == "'/home/a'\\''b/node' -")
        #expect(try SSHMetadataQuery.command(path: "C:/Users/a'b c/node.exe", shell: .powershell) == "& 'C:/Users/a''b c/node.exe' -")
        #expect(try SSHMetadataQuery.command(path: "C:/Users/a b/node.exe", shell: .commandPrompt) == "\"C:/Users/a b/node.exe\" -")
        #expect(throws: DeviceSourceFailure.unsupported) {
            try SSHMetadataQuery.command(path: "C:/Users/%PATH%/node.exe", shell: .commandPrompt)
        }
        #expect(throws: DeviceSourceFailure.invalidPath) {
            try SSHMetadataQuery.command(path: "/home/name\n/node", shell: .posix)
        }
    }

    @Test func invalidAndFailedRepliesDoNotBecomeCatalogs() throws {
        #expect(throws: DeviceSourceFailure.invalidResponse) {
            try SSHMetadataQuery.decode(Data("login banner".utf8), as: String.self)
        }
        #expect(throws: DeviceSourceFailure.changed) {
            try SSHMetadataQuery.decode(Data(#"{"failure":"changed"}"#.utf8), as: DeviceCatalogPage.self)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"] != nil))
    func queryPagesPreserveLargeIDsAndDetectSourceRewind() async throws {
        let node = try #require(ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DatabaseQueue(path: root.appendingPathComponent("logs_2.sqlite").path)
        let first: Int64 = 9_007_199_254_741_000
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE logs(id INTEGER PRIMARY KEY,ts INTEGER,thread_id TEXT,feedback_log_body TEXT)")
            for index in 0..<70 {
                try db.execute(sql: "INSERT INTO logs VALUES(?,?,?,?)", arguments: [first + Int64(index), 100, "fixture", "websocket request: fixture"])
            }
        }
        let page: DeviceTracePage = try await run(node, .init(operation: "tracePage", root: root.path, file: "logs_2.sqlite"))
        #expect(page.entries.count == 64)
        #expect(page.entries.first?.id == first)
        #expect(page.cursor.lastID == first + 63)
        #expect(page.hasMore)
        let next: DeviceTracePage = try await run(node, .init(operation: "tracePage", root: root.path,
            file: "logs_2.sqlite", cursor: .init(page.cursor)))
        #expect(next.entries.count == 6)
        #expect(!next.hasMore)
        let empty: DeviceTracePage = try await run(node, .init(operation: "tracePage", root: root.path,
            file: "logs_2.sqlite", cursor: .init(next.cursor)))
        #expect(empty.entries.isEmpty)
        try await db.write { db in
            try db.execute(sql: "DELETE FROM logs")
            try db.execute(sql: "INSERT INTO logs VALUES(1,200,'replacement','websocket request: replacement')")
        }
        let reset: DeviceTracePage = try await run(node, .init(operation: "tracePage", root: root.path,
            file: "logs_2.sqlite", cursor: .init(next.cursor)))
        #expect(reset.entries.map(\.id) == [1])
        try db.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"] != nil))
    func catalogPagesAndPathContainment() async throws {
        let node = try #require(ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,name TEXT,cwd TEXT)")
            for index in 0..<514 {
                try db.execute(sql: "INSERT INTO threads VALUES(?,?,?,?)", arguments: [String(format: "%04d", index), "old", "title", "/fixture"])
            }
        }
        try db.close()
        let desktop = root.appendingPathComponent(".codex-global-state.json")
        try Data(#"{"local-projects":{"p":{"name":"Project","rootPaths":["/fixture"]}}}"#.utf8).write(to: desktop)
        let page: DeviceCatalogPage = try await run(node, .init(operation: "catalog", root: root.path))
        #expect(page.mappings.first?.projectName == "Project")
        #expect(page.entries.count == 512)
        #expect(page.entries.first?.title == "title")
        try Data("invalid JSON".utf8).write(to: desktop)
        let last: DeviceCatalogPage = try await run(node, .init(operation: "catalog", root: root.path, after: page.next, includeDesktop: false))
        #expect(last.desktop == nil)
        #expect(last.entries.count == 2)
        #expect(last.next == nil)
        await #expect(throws: DeviceSourceFailure.invalidPath) {
            let _: DeviceTracePage = try await run(node, .init(operation: "tracePage", root: root.path, file: "../logs_2.sqlite"))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("logs_2.sqlite"), withDestinationURL: root.deletingLastPathComponent())
        await #expect(throws: DeviceSourceFailure.invalidPath) {
            let _: DeviceTracePage = try await run(node, .init(operation: "tracePage", root: root.path, file: "logs_2.sqlite"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"] != nil))
    func explicitRootWinsOverRemoteEnvironment() async throws {
        let node = try #require(ProcessInfo.processInfo.environment["TOKENTICK_TEST_NODE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let explicit = directory.appendingPathComponent("explicit")
        let environmentRoot = directory.appendingPathComponent("environment")
        try FileManager.default.createDirectory(at: explicit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: environmentRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = environmentRoot.path
        for root in [explicit.path, nil] {
            let output = try await DeviceCommand.run(executable: URL(fileURLWithPath: node), arguments: ["-"],
                input: SSHMetadataQuery.input(.init(operation: "root", root: root)), environment: environment)
            let result = try SSHMetadataQuery.decode(output.output, as: String.self)
            #expect(URL(fileURLWithPath: result).resolvingSymlinksInPath().path
                == (root == nil ? environmentRoot : explicit).resolvingSymlinksInPath().path)
        }
    }

    private func run<T: Decodable>(_ node: String, _ request: SSHMetadataQuery.Request) async throws -> T {
        let output = try await DeviceCommand.run(executable: URL(fileURLWithPath: node), arguments: ["-"],
            input: SSHMetadataQuery.input(request), timeout: 10, outputLimit: 32 * 1_024 * 1_024)
        #expect(output.status == 0)
        return try SSHMetadataQuery.decode(output.output, as: T.self)
    }
}
