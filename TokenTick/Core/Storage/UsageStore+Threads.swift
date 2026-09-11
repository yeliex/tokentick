import Foundation
import GRDB

public struct ThreadInfo: Sendable {
    public let id: String
    public let title: String?
    public let projectName: String?
    public let lastActiveAt: Double?
}

extension UsageStore {
    public func threadInfo(ids: [String]) throws -> [String: ThreadInfo] {
        let ids = Array(Set(ids)).prefix(1_000)
        guard !ids.isEmpty else { return [:] }
        return try pool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.thread_id, t.title, t.project_name,
                    (SELECT MAX(occurred_at) FROM usage WHERE thread_id = t.thread_id) AS last_active
                FROM threads t WHERE t.thread_id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: String = row["thread_id"]
                return (id, ThreadInfo(id: id, title: row["title"], projectName: row["project_name"], lastActiveAt: row["last_active"]))
            })
        }
    }
}
