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
    private let onDiagnostic: (@Sendable (SynchronizationDiagnostic) -> Void)?
    private struct APIValue: Codable {
        let login: CodexLoginStamp
        let snapshot: CurrentLimitSnapshot
    }

    public init(directory: URL? = nil, onDiagnostic: (@Sendable (SynchronizationDiagnostic) -> Void)? = nil) {
        self.onDiagnostic = onDiagnostic
        let database = ProcessInfo.processInfo.environment["TOKENTICK_DATABASE"].map { URL(fileURLWithPath: $0) }
            ?? UsageStore.defaultDatabaseURL
        self.directory = directory ?? database.deletingLastPathComponent()
    }

    public func api(for login: CodexLoginStamp) -> CurrentLimitSnapshot? {
        guard login.hasAuthenticationFile,
              let cached: APIValue = read(name: "api"), cached.login == login else { return nil }
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
        write(APIValue(login: login, snapshot: snapshot), name: "api")
    }

    public func clearAPI() {
        do { try FileManager.default.removeItem(at: directory.appendingPathComponent("api.json")) }
        catch { report(error, operation: "cache.api.delete") }
    }

    public func storage(for root: URL) -> CodexStorageSnapshot? {
        guard let value: CodexStorageSnapshot = read(name: "storage"),
              value.root == root.standardizedFileURL.resolvingSymlinksInPath(),
              (value.projectlessRoot == nil || value.projectlessRoot == CodexStorageScanner.projectlessRoot(for: root)) else { return nil }
        return value
    }

    public func saveStorage(_ snapshot: CodexStorageSnapshot) {
        write(snapshot, name: "storage")
    }

    private func read<Value: Decodable>(name: String) -> Value? {
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent(name + ".json")) }
        catch { report(error, operation: "cache.\(name).read"); return nil }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch {
            onDiagnostic?(SynchronizationDiagnostic(error: error, operation: "cache.\(name).decode", warning: true))
            return nil
        }
    }

    private func report(_ error: any Error, operation: String) {
        let cocoa = error as NSError
        guard !(cocoa.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(cocoa.code)) else { return }
        onDiagnostic?(SynchronizationDiagnostic(error: error, operation: operation, warning: true))
    }

    private func write<Value: Encodable>(_ value: Value, name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        } catch {
            // A disposable display cache must not prevent live results from reaching the UI.
            onDiagnostic?(SynchronizationDiagnostic(error: error, operation: "cache.\(name).write", warning: true))
        }
    }
}
