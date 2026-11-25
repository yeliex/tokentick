import Foundation
import GRDB

/// Codex desktop project assignments may precede project_id updates in its SQLite catalog.
struct DesktopProjectCatalog: Codable, Sendable {
    let projects: [String: Project]
    let assignments: [String: Assignment]
    let rootHints: [String: String]
    let projectless: Set<String>
    let projectlessDirectories: [String: String]

    struct Project: Codable, Sendable {
        let name: String?
        let rootPaths: [String]
    }
    struct Assignment: Codable, Sendable {
        let projectKind: String
        let projectId: String
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case projects = "local-projects"
        case assignments = "thread-project-assignments"
        case rootHints = "thread-workspace-root-hints"
        case projectless = "projectless-thread-ids"
        case projectlessDirectories = "thread-projectless-output-directories"
    }
    private struct ScopedKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(intValue: Int) { return nil }
        init(stringValue: String) { self.stringValue = stringValue }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let scoped = try decoder.container(keyedBy: ScopedKey.self)
        func directories(_ key: CodingKeys) throws -> [String: String] {
            var candidates: [String: Set<String>] = [:]
            for scope in scoped.allKeys where scope.stringValue.hasPrefix("electron-owner-value:\(key.rawValue):") {
                for (id, path) in try scoped.decode([String: String].self, forKey: scope) {
                    candidates[id, default: []].insert(path)
                }
            }
            return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
                .merging(try values.decodeIfPresent([String: String].self, forKey: key) ?? [:]) { _, unscoped in unscoped }
        }
        projects = try values.decodeIfPresent([String: Project].self, forKey: .projects) ?? [:]
        assignments = try values.decodeIfPresent([String: Assignment].self, forKey: .assignments) ?? [:]
        rootHints = try directories(.rootHints)
        projectless = try values.decodeIfPresent(Set<String>.self, forKey: .projectless) ?? []
        projectlessDirectories = try directories(.projectlessDirectories)
    }

    static func read(codexHome: URL) throws -> Self? {
        let maximum = 32 * 1_024 * 1_024
        let sqlite = codexHome.appendingPathComponent(".codex-global-state.sqlite")
        if FileManager.default.fileExists(atPath: sqlite.path) {
            let source = try CodexSourceDatabase.open(sqlite, busyTimeout: 2)
            let data = try source.read { db -> Data? in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT key, CASE WHEN length(CAST(value AS BLOB))<=? THEN value END AS value
                    FROM settings WHERE scope='global' AND (key IN (?,?,?,?,?)
                      OR key GLOB 'electron-owner-value:thread-workspace-root-hints:*'
                      OR key GLOB 'electron-owner-value:thread-projectless-output-directories:*')
                    """, arguments: StatementArguments([maximum]) + StatementArguments(CodingKeys.allCases.map(\.rawValue)))
                guard !rows.isEmpty else { return nil }
                var object: [String: Any] = [:]
                var bytes = 0
                for row in rows {
                    guard let value: String = row["value"] else { throw CatalogError.tooLarge }
                    let data = Data(value.utf8)
                    bytes += data.count
                    guard bytes <= maximum else { throw CatalogError.tooLarge }
                    object[row["key"]] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                }
                return try JSONSerialization.data(withJSONObject: object)
            }
            if let data { return try JSONDecoder().decode(Self.self, from: data) }
        }
        let url = codexHome.appendingPathComponent(".codex-global-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw CatalogError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func projectName(threadID: String, cwd: String?, stateProjectID: String? = nil, stateProjectName: String? = nil) -> String? {
        if projectless.contains(threadID) { return "Chat" }
        if let assignment = assignments[threadID] {
            guard assignment.projectKind == "local" else { return nil }
            guard let project = projects[assignment.projectId] else { return nil }
            return Self.nonemptyName(project.name) ?? Self.folderName(project.rootPaths.first)
        }
        // A recorded assignment can be unresolved. Directory hints cannot establish which project it meant.
        if stateProjectID != nil { return Self.nonemptyName(stateProjectName) }
        if projectlessDirectories[threadID] != nil { return "Chat" }
        guard let hint = rootHints[threadID] ?? cwd else { return nil }
        guard let path = Self.comparisonPath(hint) else { return nil }
        var depth = -1
        var names = Set<String>()
        for project in projects.values {
            for root in project.rootPaths {
                guard let normalizedRoot = Self.comparisonPath(root) else { continue }
                guard path == normalizedRoot || path.hasPrefix(normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/") else { continue }
                guard let name = Self.nonemptyName(project.name) ?? Self.folderName(root) else { continue }
                if normalizedRoot.count > depth { depth = normalizedRoot.count; names = [name] }
                else if normalizedRoot.count == depth { names.insert(name) }
            }
        }
        if names.count > 1 { return nil }
        return names.first
    }

    private static func comparisonPath(_ path: String) -> String? {
        // Compare Windows evidence lexically; never resolve it against this Mac's working directory.
        if path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil || path.hasPrefix("\\\\") {
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            return "windows:" + URL(fileURLWithPath: "/" + normalized).standardizedFileURL.path.lowercased()
        }
        guard path.hasPrefix("/") else { return nil }
        return "posix:" + URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func nonemptyName(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }

    /// Prefer project-root hints over temporary worktree directory names.
    static func folderName(_ path: String?) -> String? {
        guard let path else { return nil }
        if path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil || path.hasPrefix("\\\\") {
            let parts = path.split { $0 == "\\" || $0 == "/" }
            return parts.count > 1 ? parts.last.map(String.init) : nil
        }
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path == "/" ? nil : nonemptyName(url.lastPathComponent)
    }

    private enum CatalogError: LocalizedError {
        case tooLarge
        var errorDescription: String? { String(localized: "The Codex desktop project cache exceeds 32 MiB. Existing mappings were kept and reading was stopped.", bundle: .module) }
    }
}
