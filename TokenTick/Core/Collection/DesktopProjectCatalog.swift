import Foundation

/// 桌面端向 app-server 迁移项目归属期间，SQLite 中的 project_id 可能尚未回填。
struct DesktopProjectCatalog: Decodable {
    let projects: [String: Project]
    let assignments: [String: Assignment]
    let rootHints: [String: String]
    let projectless: Set<String>

    struct Project: Decodable {
        let name: String
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
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([String: Project].self, forKey: .projects) ?? [:]
        assignments = try values.decodeIfPresent([String: Assignment].self, forKey: .assignments) ?? [:]
        rootHints = try values.decodeIfPresent([String: String].self, forKey: .rootHints) ?? [:]
        projectless = try values.decodeIfPresent(Set<String>.self, forKey: .projectless) ?? []
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
        if projectless.contains(threadID) { return nil }
        if let assignment = assignments[threadID] {
            guard assignment.projectKind == "local" else { return nil }
            return projects[assignment.projectId]?.name
        }
        guard let hint = rootHints[threadID] ?? cwd else { return nil }
        let path = URL(fileURLWithPath: hint).standardizedFileURL.path
        var depth = -1
        var names = Set<String>()
        for project in projects.values {
            for root in project.rootPaths {
                let root = URL(fileURLWithPath: root).standardizedFileURL.path
                guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }
                if root.count > depth { depth = root.count; names = [project.name] }
                else if root.count == depth { names.insert(project.name) }
            }
        }
        return names.count == 1 ? names.first : nil
    }

    private enum CatalogError: LocalizedError {
        case tooLarge
        var errorDescription: String? { "Codex 桌面项目缓存超过 32 MiB，保留现有映射并停止读取。" }
    }
}
