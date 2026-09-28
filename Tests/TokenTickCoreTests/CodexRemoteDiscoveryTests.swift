import Foundation
import Testing
@testable import TokenTickCore

struct CodexRemoteDiscoveryTests {
    @Test func onlyExplicitEnvironmentHintsAreUsed() throws {
        let data = Data(#"{"added-remote-control-env-ids":["env-fixture","env-fixture","","invalid id"],"selected-remote-host-id":"ssh://do-not-infer","remote-projects":[{"hostId":"not-enrolled"}]}"#.utf8)
        #expect(try CodexRemoteDiscovery.decode(data) == ["env-fixture"])
        #expect(try CodexRemoteDiscovery.decode(Data("{}".utf8)).isEmpty)
        #expect(throws: DecodingError.self) { try CodexRemoteDiscovery.decode(Data(#"{"added-remote-control-env-ids":5}"#.utf8)) }
    }

    @Test func dismissalsSurviveReloadWithoutCreatingConnections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceConfigurationStore(directory: root)
        try store.update { $0.dismissedRemoteHintIDs = ["env-fixture"] }
        let loaded = try store.load()
        #expect(loaded.devices.isEmpty)
        #expect(loaded.dismissedRemoteHintIDs == ["env-fixture"])
        #expect(Set(["env-fixture", "env-new"]).subtracting(loaded.dismissedRemoteHintIDs ?? []) == ["env-new"])
    }
}
