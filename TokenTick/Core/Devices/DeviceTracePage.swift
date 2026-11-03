import CryptoKit
import Foundation
import GRDB

/// Authentication rows expose only the turn identifier and mode. Never transfer their headers or diagnostics.
struct DeviceTracePage: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let id: Int64
        let timestamp: Int64
        let threadID: String?
        let body: String
        var authTurn: String? = nil
        var authMode: String? = nil
    }
    let entries: [Entry]
    let cursor: CodexFastEvidence.Cursor
    let hasMore: Bool

    // Shared with the SSH reader. Older trace schemas can supply NULL for either optional column.
    static let pageSQL = """
        WITH candidates AS (
            SELECT id,ts AS timestamp,TRACE_THREAD AS threadID,feedback_log_body AS raw,
                TRACE_TARGET='feedback_tags' AND instr(feedback_log_body,'run_sampling_request{turn_id=')>0
                AND instr(feedback_log_body,'}: endpoint="/responses" auth_header_attached=true')>0
                AND instr(feedback_log_body,' auth_error=""')>0 AS auth
            FROM logs WHERE id>? AND id<=? AND length(CAST(feedback_log_body AS BLOB))<=4194304
        )
        SELECT id,timestamp,threadID,CASE WHEN auth THEN '' ELSE raw END AS body,
            CASE WHEN auth THEN substr(raw,instr(raw,'run_sampling_request{turn_id=')+length('run_sampling_request{turn_id='),36) END AS authTurn,
            CASE WHEN auth THEN CASE
                WHEN instr(raw,' auth_mode="Chatgpt"')>0 THEN 'chatgpt'
                WHEN instr(raw,' auth_mode="ApiKey"')>0 THEN 'api_key'
                ELSE 'unknown' END END AS authMode
        FROM candidates WHERE auth OR raw LIKE '%websocket request:%' OR raw LIKE '%Submission sub=Submission {%'
        ORDER BY id LIMIT 65
        """

    static func files(root: URL) throws -> [String] {
        guard try root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw DeviceSourceFailure.unsupported
        }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("logs_") && $0.hasSuffix(".sqlite") }.sorted()
    }

    static func read(root: URL, file: String, previous: CodexFastEvidence.Cursor?) throws -> Self {
        guard try files(root: root).contains(file), !file.contains("/"), !file.contains("\\") else {
            throw DeviceSourceFailure.invalidPath
        }
        let url = root.appendingPathComponent(file).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw DeviceSourceFailure.invalidPath
        }
        let source = try CodexSourceDatabase.open(url, busyTimeout: 2)
        defer { try? source.close() }
        let snapshot = try FileSnapshot(url: url, compressed: false)
        return try source.read { db in
            let maximum = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM logs") ?? 0
            func anchor(_ id: Int64) throws -> String? {
                try String.fetchOne(db, sql: "SELECT json_array(ts,length(feedback_log_body),substr(feedback_log_body,1,512)) FROM logs WHERE id=?", arguments: [id])
                    .map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
            }
            var start: Int64 = 0
            if let previous, previous.inode == snapshot.inode, previous.device == snapshot.device,
               previous.lastID <= maximum, try previous.anchor == anchor(previous.lastID) { start = previous.lastID }
            let columns = try db.columns(in: "logs").map(\.name)
            let sql = pageSQL.replacingOccurrences(of: "TRACE_THREAD", with: columns.contains("thread_id") ? "thread_id" : "NULL")
                .replacingOccurrences(of: "TRACE_TARGET", with: columns.contains("target") ? "target" : "NULL")
            let rows = try Row.fetchCursor(db, sql: sql, arguments: [start, maximum])
            var entries: [Entry] = []
            var bytes = 0
            var more = false
            while let row = try rows.next() {
                let entry = Entry(id: row["id"], timestamp: row["timestamp"], threadID: row["threadID"], body: row["body"],
                                  authTurn: row["authTurn"], authMode: row["authMode"])
                let size = try JSONEncoder().encode(entry).count
                if !entries.isEmpty && (entries.count >= 64 || bytes + size > 8 * 1_024 * 1_024) { more = true; break }
                entries.append(entry); bytes += size
            }
            let last = more ? entries.last!.id : maximum
            return Self(entries: entries, cursor: CodexFastEvidence.Cursor(inode: snapshot.inode, device: snapshot.device,
                lastID: last, anchor: try anchor(last)), hasMore: more)
        }
    }
}

protocol DeviceTraceSource: Sendable {
    func traceFiles() async throws -> [String]
    func tracePage(file: String, cursor: CodexFastEvidence.Cursor?) async throws -> DeviceTracePage
}
