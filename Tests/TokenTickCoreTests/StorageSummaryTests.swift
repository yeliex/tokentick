import Foundation
import Testing
@testable import TokenTickCore

struct StorageSummaryTests {
    @Test func reportsLiveFilesWithoutCreatingBackupsOrChangingFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let before = try store.tableCounts()
        let summary = try store.storageSummary()
        func bytes(_ suffix: String) throws -> Int64 {
            let path = store.databaseURL.path + suffix
            if !FileManager.default.fileExists(atPath: path) { return 0 }
            return try Int64(URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        }
        #expect(summary.databaseBytes == (try bytes("")))
        #expect(summary.walBytes == (try bytes("-wal")))
        #expect(summary.sharedMemoryBytes == (try bytes("-shm")))
        #expect(summary.liveBytes == summary.databaseBytes + summary.walBytes + summary.sharedMemoryBytes)
        #expect(try store.tableCounts() == before)
    }

}
