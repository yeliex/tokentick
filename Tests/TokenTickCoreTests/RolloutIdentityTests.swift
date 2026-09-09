import Foundation
import Testing
@testable import TokenTickCore

struct RolloutIdentityTests {
    let thread = "01900000-0000-7000-8000-000000000001"
    let reverted = "01900000-0000-7000-8000-000000000002"

    @Test func ordinaryAndCompressedKeepLogicalIdentity() throws {
        let name = "rollout-2026-09-09T10-20-30-\(thread).jsonl"
        let plain = try #require(RolloutIdentity(fileName: name))
        let compressed = try #require(RolloutIdentity(fileName: name + ".zst"))
        #expect(plain.threadID == plain.rolloutID)
        #expect(plain.rolloutID == compressed.rolloutID)
        #expect(plain.fileName == compressed.fileName)
        #expect(compressed.isCompressed)
    }

    @Test func revertKeepsThreadButHasIndependentRollout() throws {
        let original = try #require(RolloutIdentity(fileName: "rollout-2026-09-09T10-20-30-\(thread).jsonl"))
        let changed = try #require(RolloutIdentity(fileName: "rollout-2026-09-09T11-20-30-\(thread)_\(reverted).jsonl"))
        #expect(original.threadID == changed.threadID)
        #expect(original.rolloutID != changed.rolloutID)
    }

    @Test(arguments: ["arbitrary.jsonl", "rollout-bad.jsonl", "rollout-2026-09-09T10-20-30-invalid.jsonl"])
    func unrelatedFilesAreNotGuessed(name: String) {
        #expect(RolloutIdentity(fileName: name) == nil)
    }
}
