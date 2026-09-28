import Foundation
import Testing
@testable import TokenTickCore

struct SFTPClientTests {
    @Test func readsRangesAndDirectoryThroughNativeServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("日志.jsonl")
        let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: path)
        let transport = try SFTPTransport(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-R"])
        let client = SFTPClient(transport: transport)
        do {
            let canonical = try await client.realpath(root.path)
            #expect(canonical.hasPrefix("/"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: canonical).appendingPathComponent("日志.jsonl")) == bytes)
            #expect(try await client.stat(path.path).size == UInt64(bytes.count))
            let handle = try await client.open(path.path)
            #expect(try await client.read(handle, offset: 0, count: 131_072) == bytes)
            #expect(try await client.read(handle, offset: 50_123, count: 321) == bytes.subdata(in: 50_123..<50_444))
            #expect(try await client.read(handle, offset: 99_990, count: 32_768) == bytes.suffix(10))
            #expect(try await client.read(handle, offset: 100_000, count: 1).isEmpty)
            try await client.closeHandle(handle)
            let directory = try await client.open(root.path, directory: true)
            var names: [String] = []
            while let page = try await client.entries(directory) { names += page.map(\.name) }
            #expect(names.contains("日志.jsonl"))
            try await client.closeHandle(directory)
            await #expect(throws: SFTPClient.Status(code: 2)) { try await client.stat(root.appendingPathComponent("missing").path) }
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }
}
