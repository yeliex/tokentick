import Foundation

/// Codex desktop project assignments may precede project_id updates in its SQLite catalog.
struct DesktopProjectCatalog: Decodable {
    let projects: [String: Project]
    let assignments: [String: Assignment]
    let rootHints: [String: String]
    let projectless: Set<String>
    let projectlessDirectories: [String: String]

    struct Project: Decodable {
        let name: String?
        let rootPaths: [String]
    }
    struct Assignment: Decodable {
        let projectKind: String
        let projectId: String
    }
    private enum CodingKeys: String, CodingKey {
        case projects = "local-projects"
        case assignments = "thread-project-assignments"
        case rootHints = "thread-workspace-root-hints"
        case projectless = "projectless-thread-ids"
        case projectlessDirectories = "thread-projectless-output-directories"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([String: Project].self, forKey: .projects) ?? [:]
        assignments = try values.decodeIfPresent([String: Assignment].self, forKey: .assignments) ?? [:]
        rootHints = try values.decodeIfPresent([String: String].self, forKey: .rootHints) ?? [:]
        projectless = try values.decodeIfPresent(Set<String>.self, forKey: .projectless) ?? []
        projectlessDirectories = try values.decodeIfPresent([String: String].self, forKey: .projectlessDirectories) ?? [:]
    }

    static func read(codexHome: URL) throws -> Self? {
        let url = codexHome.appendingPathComponent(".codex-global-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximum = 32 * 1_024 * 1_024
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw CatalogError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func projectName(threadID: String, cwd: String?) -> String? {
        if projectless.contains(threadID) { return "Chat" }
        if let assignment = assignments[threadID] {
            guard assignment.projectKind == "local" else { return nil }
            guard let project = projects[assignment.projectId] else { return nil }
            return Self.nonemptyName(project.name) ?? Self.folderName(project.rootPaths.first)
        }
        if projectlessDirectories[threadID] != nil { return "Chat" }
        guard let hint = rootHints[threadID] ?? cwd else { return nil }
        // Remote Windows paths must not be resolved as relative paths on this Mac.
        guard hint.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: hint).standardizedFileURL.path
        var depth = -1
        var names = Set<String>()
        for project in projects.values {
            for root in project.rootPaths {
                guard root.hasPrefix("/") else { continue }
                let root = URL(fileURLWithPath: root).standardizedFileURL.path
                guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }
                guard let name = Self.nonemptyName(project.name) ?? Self.folderName(root) else { continue }
                if root.count > depth { depth = root.count; names = [name] }
                else if root.count == depth { names.insert(name) }
            }
        }
        if names.count > 1 { return nil }
        return names.first
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
