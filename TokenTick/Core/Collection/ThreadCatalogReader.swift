import Foundation
import GRDB

/// 只读取 Codex 自己的最新映射；不采集 preview、正文、权限设置或认证数据。
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
                batch.append(ThreadMapping(threadID: id.lowercased(), title: row["title"],
                                           projectName: project ?? desktop?.projectName(threadID: id, cwd: cwd)))
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
        var errorDescription: String? { "Codex 任务数据库字段与已验证格式不兼容，保留现有名称缓存。" }
    }
}

struct ThreadMapping {
    let threadID: String
    let title: String?
    let projectName: String?
}

extension UsageStore {
    func updateThreadMappings(_ mappings: [ThreadMapping]) throws -> Int {
        try pool.write { db in
            var changed = 0
            for mapping in mappings {
                try db.execute(sql: """
                    INSERT INTO threads(thread_id, title, project_name) VALUES (?, ?, ?)
                    ON CONFLICT(thread_id) DO UPDATE SET title = excluded.title, project_name = excluded.project_name
                    WHERE threads.title IS NOT excluded.title OR threads.project_name IS NOT excluded.project_name
                    """, arguments: [mapping.threadID, mapping.title, mapping.projectName])
                changed += db.changesCount
            }
            if changed > 0 {
                try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('statistics_dirty', 'true') ON CONFLICT(key) DO UPDATE SET value = 'true'")
            }
            return changed
        }
    }
}
