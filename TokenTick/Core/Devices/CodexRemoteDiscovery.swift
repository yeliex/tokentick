import Foundation

/// Desktop environment IDs are hints, never SSH hosts or proof that a device is connected.
public enum CodexRemoteDiscovery {
    private struct State: Decodable {
        let environments: [String]?
        enum CodingKeys: String, CodingKey { case environments = "added-remote-control-env-ids" }
    }

    public static func read(codexHome: URL = LocalUsageScanner.defaultCodexHome) throws -> Set<String> {
        let url = codexHome.appendingPathComponent(".codex-global-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximum = 32 * 1_024 * 1_024
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw DeviceSourceFailure.unsupported }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Set<String> {
        let state = try JSONDecoder().decode(State.self, from: data)
        return Set((state.environments ?? []).filter {
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains(where: { $0.isWhitespace || $0.isNewline })
        })
    }
}
