import Foundation
import GRDB

public struct ThreadInfo: Sendable, Equatable {
    public let id: String
    public let title: String?
    public let projectName: String?
    public let lastActiveAt: Double?
    public let parentThreadID: String?
    public let parentTitle: String?
    public let agentNickname: String?
}

extension UsageStore {
    public func threadInfo(ids: [String], device: String? = nil) throws -> [String: ThreadInfo] {
        let ids = Array(Set(ids)).prefix(1_000)
        guard !ids.isEmpty else { return [:] }
        return try pool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.thread_id, t.title, t.project_name, t.parent_thread_id, p.title AS parent_title, t.agent_nickname,
                    (SELECT MAX(occurred_at) FROM usage WHERE thread_id = t.thread_id AND device = t.device) AS last_active
                FROM threads t LEFT JOIN threads p ON p.thread_id=t.parent_thread_id AND p.device=t.device
                WHERE t.thread_id IN (\(placeholders)) AND (? IS NULL OR t.device=?)
                ORDER BY last_active DESC, t.device != 'local', t.device
                """, arguments: StatementArguments(Array(ids).map { Optional($0) } + [device, device]))
            return Dictionary(rows.map { row in
                let id: String = row["thread_id"]
                return (id, ThreadInfo(id: id, title: row["title"], projectName: row["project_name"], lastActiveAt: row["last_active"],
                                      parentThreadID: row["parent_thread_id"], parentTitle: row["parent_title"], agentNickname: row["agent_nickname"]))
            }, uniquingKeysWith: { first, _ in first })
        }
    }
}

struct ThreadMapping {
    let threadID: String
    let title: String?
    let projectName: String?
    var parentThreadID: String? = nil
    var agentNickname: String? = nil
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
                let parent = DesktopProjectCatalog.nonemptyName(mapping.parentThreadID)?.lowercased()
                let parentID = parent == mapping.threadID ? nil : parent
                try db.execute(sql: """
                    INSERT INTO threads(thread_id, device, title, project_name, parent_thread_id, agent_nickname) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(thread_id, device) DO UPDATE SET title=excluded.title,
                        project_name=CASE WHEN COALESCE(excluded.parent_thread_id,threads.parent_thread_id) IS NULL
                            THEN excluded.project_name ELSE threads.project_name END,
                        parent_thread_id=COALESCE(excluded.parent_thread_id,threads.parent_thread_id),
                        agent_nickname=COALESCE(excluded.agent_nickname,threads.agent_nickname)
                    WHERE threads.title IS NOT excluded.title
                        OR (threads.parent_thread_id IS NULL AND excluded.parent_thread_id IS NULL AND threads.project_name IS NOT excluded.project_name)
                        OR (excluded.parent_thread_id IS NOT NULL AND threads.parent_thread_id IS NOT excluded.parent_thread_id)
                        OR (excluded.agent_nickname IS NOT NULL AND threads.agent_nickname IS NOT excluded.agent_nickname)
                    """, arguments: [mapping.threadID, device, mapping.title, parentID == nil ? mapping.projectName : nil,
                                      parentID, DesktopProjectCatalog.nonemptyName(mapping.agentNickname)])
                changed += db.changesCount
            }
            // Resolve once the catalog is complete, when parent and child mappings are both available.
            if catalogCheckpoint?.next == nil {
                try db.execute(sql: """
                    WITH RECURSIVE inherited(thread_id, project_name) AS MATERIALIZED (
                        SELECT thread_id, project_name FROM threads WHERE device=? AND parent_thread_id IS NULL
                        UNION ALL
                        SELECT child.thread_id, parent.project_name FROM inherited parent
                        JOIN threads child ON child.device=? AND child.parent_thread_id=parent.thread_id
                    )
                    UPDATE threads AS child SET project_name=(SELECT project_name FROM inherited WHERE thread_id=child.thread_id)
                    WHERE child.device=? AND child.parent_thread_id IS NOT NULL
                        AND child.project_name IS NOT (SELECT project_name FROM inherited WHERE thread_id=child.thread_id)
                    """, arguments: [device, device, device])
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
