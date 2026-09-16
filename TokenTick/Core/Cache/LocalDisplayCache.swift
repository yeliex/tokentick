import Foundation

public struct CodexLoginStamp: Codable, Equatable, Sendable {
    public let home: String
    public let modified: Date?
    public let size: UInt64?
    public let inode: UInt64?

    public init(home: URL) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path)
        modified = attributes?[.modificationDate] as? Date
        size = attributes?[.size] as? UInt64
        inode = attributes?[.systemFileNumber] as? UInt64
    }

    var hasAuthenticationFile: Bool { modified != nil && size != nil && inode != nil }
}

public actor LocalDisplayCache {
    private let directory: URL
    private struct APIValue: Codable {
        let login: CodexLoginStamp
        let snapshot: CurrentLimitSnapshot
    }

    public init(directory: URL? = nil) {
        let database = ProcessInfo.processInfo.environment["TOKENTICK_DATABASE"].map { URL(fileURLWithPath: $0) }
            ?? UsageStore.defaultDatabaseURL
        self.directory = directory ?? database.deletingLastPathComponent()
    }

    public func api(for login: CodexLoginStamp) -> CurrentLimitSnapshot? {
        guard login.hasAuthenticationFile,
              let data = try? Data(contentsOf: directory.appendingPathComponent("api.json")),
              let cached = try? JSONDecoder().decode(APIValue.self, from: data), cached.login == login else { return nil }
        return cached.snapshot
    }

    public func saveAPI(_ value: CurrentLimitSnapshot, login: CodexLoginStamp) {
        guard login.hasAuthenticationFile, value.source == "api", let account = value.accountID, !account.isEmpty else { return }
        // Persist display fields only, without the raw API response or source evidence.
        var snapshot = CurrentLimitSnapshot(accountID: account, observedAt: value.observedAt, source: "api",
            scopeKey: value.scopeKey, windows: value.windows, sourceJSON: "{}")
        snapshot.planType = value.planType
        snapshot.availableResets = value.availableResets
        snapshot.resetCreditExpirations = value.resetCreditExpirations
        snapshot.creditsBalance = value.creditsBalance
        snapshot.unlimitedCredits = value.unlimitedCredits
        write(APIValue(login: login, snapshot: snapshot), name: "api.json")
    }

    public func clearAPI() { try? FileManager.default.removeItem(at: directory.appendingPathComponent("api.json")) }

    public func storage(for root: URL) -> CodexStorageSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("storage.json")),
              let value = try? JSONDecoder().decode(CodexStorageSnapshot.self, from: data),
              value.root == root.standardizedFileURL.resolvingSymlinksInPath(),
              (value.projectlessRoot == nil || value.projectlessRoot == CodexStorageScanner.projectlessRoot(for: root)) else { return nil }
        return value
    }

    public func saveStorage(_ snapshot: CodexStorageSnapshot) {
        write(snapshot, name: "storage.json")
    }

    private func write<Value: Encodable>(_ value: Value, name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            // A disposable display cache must not prevent live results from reaching the UI.
            NSLog("TokenTick display cache: %@", error.localizedDescription)
        }
    }
}
