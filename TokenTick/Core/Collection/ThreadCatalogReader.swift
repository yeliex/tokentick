import Foundation
import GRDB

/// Read current Codex mappings only, excluding previews, bodies, permissions, and authentication data.
struct ThreadCatalogReader {
    func refresh(codexHome: URL, store: UsageStore) throws -> Int? {
        let files = try FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)
        let databases = files.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }.sorted { $0.0 > $1.0 }
        guard let url = databases.first?.1 else { return nil }
        let desktop = try DesktopProjectCatalog.read(codexHome: codexHome)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2)
        let source = try DatabaseQueue(path: url.path, configuration: configuration)
        return try source.read { db in
            let columns = Set(try db.columns(in: "threads").map(\.name))
            guard columns.contains("id"), columns.contains("title") else { throw CatalogError.unsupportedSchema }
            let title = columns.contains("name") ? "COALESCE(NULLIF(t.name, ''), t.title)" : "t.title"
            let hasProjects = try columns.contains("project_id") && db.tableExists("projects")
            if hasProjects {
                let projectColumns = Set(try db.columns(in: "projects").map(\.name))
                guard projectColumns.isSuperset(of: ["id", "name"]) else { throw CatalogError.unsupportedSchema }
            }
            let cwd = columns.contains("cwd") ? "t.cwd" : "NULL"
            let query = "SELECT t.id AS thread_id, \(title) AS title, \(cwd) AS cwd, "
                + (hasProjects ? "p.name AS project_name FROM threads t LEFT JOIN projects p ON p.id = t.project_id" : "NULL AS project_name FROM threads t")
            let cursor = try Row.fetchCursor(db, sql: query)
            var batch: [ThreadMapping] = []
            var changed = 0
            while let row = try cursor.next() {
                let id: String = row["thread_id"]
                let project: String? = row["project_name"]
                let cwd: String? = row["cwd"]
                let resolved = if let desktop { desktop.projectName(threadID: id, cwd: cwd) }
                    else { DesktopProjectCatalog.nonemptyName(project) }
                batch.append(ThreadMapping(threadID: id.lowercased(), title: row["title"],
                                           projectName: resolved))
                if batch.count == 512 {
                    changed += try store.updateThreadMappings(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            changed += try store.updateThreadMappings(batch)
            return changed
        }
    }

    private enum CatalogError: LocalizedError {
        case unsupportedSchema
        var errorDescription: String? { String(localized: "Codex task database fields are incompatible with the verified format. The existing name cache was kept.", bundle: .module) }
    }
}
