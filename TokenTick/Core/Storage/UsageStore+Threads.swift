import Foundation
import GRDB

public struct ThreadInfo: Sendable, Equatable {
    public let id: String
    public let title: String?
    public let projectName: String?
    public let lastActiveAt: Double?
}

extension UsageStore {
    public func threadInfo(ids: [String], device: String? = nil) throws -> [String: ThreadInfo] {
        let ids = Array(Set(ids)).prefix(1_000)
        guard !ids.isEmpty else { return [:] }
        return try pool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.thread_id, t.title, t.project_name,
                    (SELECT MAX(occurred_at) FROM usage WHERE thread_id = t.thread_id AND device = t.device) AS last_active
                FROM threads t WHERE t.thread_id IN (\(placeholders)) AND (? IS NULL OR t.device=?)
                ORDER BY last_active DESC, t.device != 'local', t.device
                """, arguments: StatementArguments(Array(ids).map { Optional($0) } + [device, device]))
            return Dictionary(rows.map { row in
                let id: String = row["thread_id"]
                return (id, ThreadInfo(id: id, title: row["title"], projectName: row["project_name"], lastActiveAt: row["last_active"]))
            }, uniquingKeysWith: { first, _ in first })
        }
    }
}

struct ThreadMapping {
    let threadID: String
    let title: String?
    let projectName: String?
}

extension UsageStore {
    func deviceCatalogCursor(device: String, sourceRevision: Int) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?",
                                arguments: ["device_catalog_cursor:\(device):\(sourceRevision)"])
        }
    }

    func updateThreadMappings(_ mappings: [ThreadMapping], device: String = "local",
                              catalogCheckpoint: (sourceRevision: Int, next: String?)? = nil) throws -> Int {
        try pool.write { db in
            var changed = 0
            for mapping in mappings {
                try db.execute(sql: """
                    INSERT INTO threads(thread_id, device, title, project_name) VALUES (?, ?, ?, ?)
                    ON CONFLICT(thread_id, device) DO UPDATE SET title = excluded.title, project_name = excluded.project_name
                    WHERE threads.title IS NOT excluded.title OR threads.project_name IS NOT excluded.project_name
                    """, arguments: [mapping.threadID, device, mapping.title, mapping.projectName])
                changed += db.changesCount
            }
            if let checkpoint = catalogCheckpoint {
                let key = "device_catalog_cursor:\(device):\(checkpoint.sourceRevision)"
                if let next = checkpoint.next {
                    try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                                   arguments: [key, next])
                } else {
                    try db.execute(sql: "DELETE FROM app_metadata WHERE key=?", arguments: [key])
                }
            }
            return changed
        }
    }
}
