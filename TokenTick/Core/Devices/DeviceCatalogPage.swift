import Foundation
import GRDB

struct DeviceCatalogPage: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let id: String
        let title: String?
        let projectName: String?
        let cwd: String?
        var projectID: String? = nil
        var parentThreadID: String? = nil
        var agentNickname: String? = nil
    }
    let entries: [Entry]
    let desktop: DesktopProjectCatalog?
    let next: String?
    let available: Bool

    var mappings: [ThreadMapping] {
        entries.map { entry in
            let projectName = if let desktop {
                desktop.projectName(threadID: entry.id, cwd: entry.cwd,
                    stateProjectID: entry.projectID, stateProjectName: entry.projectName)
            } else {
                DesktopProjectCatalog.nonemptyName(entry.projectName)
            }
            return ThreadMapping(threadID: entry.id.lowercased(), title: DesktopProjectCatalog.nonemptyName(entry.title),
                projectName: projectName,
                parentThreadID: entry.parentThreadID, agentNickname: entry.agentNickname)
        }
    }

    static func read(root: URL, after: String?) throws -> Self {
        try Reader(root: root).read(after: after)
    }

    /// One source connection and desktop snapshot per collection pass; each page has its own read transaction.
    final class Reader {
        private let source: DatabaseQueue?
        private let desktop: DesktopProjectCatalog?

        init(root: URL) throws {
            // SQLite WAL and locking guarantees have not been verified for network filesystems.
            guard try root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
                throw DeviceSourceFailure.unsupported
            }
            let databases = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url -> (Int, URL)? in
                let name = url.lastPathComponent
                guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
                return (version, url)
            }.sorted { $0.0 > $1.0 }
            guard let url = databases.first?.1 else { source = nil; desktop = nil; return }
            for file in [url, root.appendingPathComponent(".codex-global-state.json"), root.appendingPathComponent(".codex-global-state.sqlite")] {
                guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                    throw DeviceSourceFailure.invalidPath
                }
            }
            source = try CodexSourceDatabase.open(url, busyTimeout: 2)
            desktop = try DesktopProjectCatalog.read(codexHome: root)
        }

        deinit { try? source?.close() }

        func read(after: String?) throws -> DeviceCatalogPage {
            guard let source else { return DeviceCatalogPage(entries: [], desktop: nil, next: nil, available: false) }
            return try source.read { db in
                let columns = Set(try db.columns(in: "threads").map(\.name))
                guard columns.isSuperset(of: ["id", "title"]) else { throw DeviceSourceFailure.unsupported }
                let title = columns.contains("name") ? "COALESCE(NULLIF(TRIM(t.name),''),NULLIF(TRIM(t.title),''))" : "NULLIF(TRIM(t.title),'')"
                let projects = try columns.contains("project_id") && db.tableExists("projects")
                if projects, try !Set(db.columns(in: "projects").map(\.name)).isSuperset(of: ["id", "name"]) {
                    throw DeviceSourceFailure.unsupported
                }
                let cwd = columns.contains("cwd") ? "t.cwd" : "NULL"
                let projectID = columns.contains("project_id") ? "t.project_id" : "NULL"
                let join = projects ? "p.name AS project_name FROM threads t LEFT JOIN projects p ON p.id=t.project_id" : "NULL AS project_name FROM threads t"
                let spawn = columns.contains("source") ? "CASE WHEN json_valid(t.source) THEN json_extract(t.source,'$.subagent.thread_spawn.parent_thread_id') END" : "NULL"
                let sourceNickname = columns.contains("source") ? "CASE WHEN json_valid(t.source) THEN json_extract(t.source,'$.subagent.thread_spawn.agent_nickname') END" : "NULL"
                let nickname = columns.contains("agent_nickname") ? "COALESCE(NULLIF(TRIM(t.agent_nickname),''),\(sourceNickname))" : sourceNickname
                let edges = try db.tableExists("thread_spawn_edges")
                    && Set(db.columns(in: "thread_spawn_edges").map(\.name)).isSuperset(of: ["child_thread_id", "parent_thread_id"])
                let parent = edges
                    ? "COALESCE(\(spawn),(SELECT CASE WHEN COUNT(DISTINCT e.parent_thread_id)=1 THEN MIN(e.parent_thread_id) END FROM thread_spawn_edges e WHERE e.child_thread_id=t.id))"
                    : spawn
                let rows = try Row.fetchAll(db, sql: """
                    SELECT t.id,\(title) AS title,\(cwd) AS cwd,\(projectID) AS project_id,\(parent) AS parent_id,\(nickname) AS agent_nickname,\(join)
                    WHERE (? IS NULL OR t.id>?) ORDER BY t.id LIMIT 513
                    """, arguments: [after, after])
                let entries = rows.prefix(512).map { Entry(id: $0["id"], title: $0["title"], projectName: $0["project_name"],
                    cwd: $0["cwd"], projectID: $0["project_id"], parentThreadID: $0["parent_id"], agentNickname: $0["agent_nickname"]) }
                return DeviceCatalogPage(entries: entries, desktop: desktop, next: rows.count > 512 ? entries.last?.id : nil, available: true)
            }
        }
    }
}
