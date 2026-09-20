import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct CodexSourceDatabaseTests {
    @Test func missingSourceReportsAccessConditionsWithoutCreatingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state_5.sqlite")
        do {
            _ = try CodexSourceDatabase.open(url, busyTimeout: 0)
            Issue.record("Opening a missing source must fail")
        } catch {
            let value = error as NSError
            #expect(value.domain == "TokenTickCore.CodexSourceDatabase")
            #expect(value.code & 0xff == 14)
            #expect(value.userInfo[NSFilePathErrorKey] as? String == url.path)
            #expect(value.localizedDescription.contains("state_5.sqlite: exists=false"))
            #expect(value.localizedDescription.contains("state_5.sqlite-wal: exists=false"))
            #expect(value.localizedDescription.contains("state_5.sqlite-shm: exists=false"))
            #expect(value.localizedDescription.contains("directory=true, readable=true"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func sourceConnectionCannotWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("logs_2.sqlite")
        let writer = try DatabaseQueue(path: url.path)
        try writer.write { try $0.execute(sql: "CREATE TABLE logs(id INTEGER)") }
        try writer.close()
        let source = try CodexSourceDatabase.open(url, busyTimeout: 0.25)
        defer { try? source.close() }
        #expect(try source.read { try $0.tableExists("logs") })
        #expect(throws: DatabaseError.self) {
            try source.write { try $0.execute(sql: "INSERT INTO logs VALUES (1)") }
        }
        #expect(try source.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM logs") } == 0)
    }
}
