import CryptoKit
import Foundation
import GRDB

/// 只缓存统计所需的 Fast 证据；不复制 trace 中的请求正文。
struct CodexFastEvidence: Codable {
    let threadID: String
    let turnID: String
    let fileName: String
    let rowID: Int64
    let observedAt: Int64
    let kind: String

    var key: String { "fast_trace:\(threadID):\(turnID)" }

    static func parse(body: String, threadID: String?, fileName: String, rowID: Int64, timestamp: Int64) -> Self? {
        let thread: String?
        let turn: String?
        let kind: String
        if let marker = body.range(of: "websocket request:") {
            let prefix = String(body[..<marker.lowerBound])
            guard let request = (try? JSONSerialization.jsonObject(with: Data(body[marker.upperBound...].utf8))) as? [String: Any],
                  request["type"] as? String == "response.create",
                  CodexServiceTier.isFast(request["service_tier"] as? String) == true else { return nil }
            thread = value("thread_id", in: prefix) ?? threadID
            turn = value("turn.id", in: prefix) ?? value("turn_id", in: prefix) ?? request["turn_id"] as? String
            kind = "websocket_request"
        } else if let marker = body.range(of: "Submission sub=Submission {") {
            let prefix = String(body[..<marker.lowerBound])
            let submission = String(body[marker.upperBound...])
            // ThreadSettings 更新的 Submission ID 不是 turn ID；只接受真正提交轮次的操作。
            guard submission.range(of: #"^\s*id: "[^"]+", op: (TurnInput|UserInput) \{"#, options: .regularExpression) != nil else { return nil }
            let pattern = #"service_tier:\s*Some\(Some\("(?:priority|fast)"\)\)"#
            guard let match = submission.range(of: pattern, options: .regularExpression),
                  !insideQuotedString(submission[..<match.lowerBound]) else { return nil }
            thread = value("thread_id", in: prefix) ?? threadID
            turn = submission.components(separatedBy: "id: \"").dropFirst().first?.components(separatedBy: "\"").first
            kind = "turn_submission"
        } else { return nil }
        guard let thread, let turn, let threadUUID = UUID(uuidString: thread), let turnUUID = UUID(uuidString: turn),
              threadID == nil || threadID?.lowercased() == threadUUID.uuidString.lowercased() else { return nil }
        return Self(threadID: threadUUID.uuidString.lowercased(), turnID: turnUUID.uuidString.lowercased(),
                    fileName: fileName, rowID: rowID, observedAt: timestamp, kind: kind)
    }

    private static func value(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: name + "=") else { return nil }
        return String(text[range.upperBound...].prefix { !$0.isWhitespace && !",]}):".contains($0) })
    }

    private static func insideQuotedString(_ prefix: Substring) -> Bool {
        var quoted = false
        var escaped = false
        for character in prefix {
            if escaped { escaped = false }
            else if character == "\\" && quoted { escaped = true }
            else if character == "\"" { quoted.toggle() }
        }
        return quoted
    }

    struct Cursor: Codable {
        let inode: UInt64
        let device: UInt64
        let lastID: Int64
        let anchor: String?
    }

    /// 调用者持有目标数据库的写锁。trace 用只读连接，证据与游标同事务提交。
    static func collect(codexHome: URL, store: UsageStore) throws {
        let urls = try FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" }.sorted { $0.path < $1.path }
        for url in urls {
            try Task.checkCancellation()
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(0.25)
            let source = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? source.close() }
            let file = try FileSnapshot(url: url, compressed: false)
            let key = "fast_trace_cursor:" + url.standardizedFileURL.path
            let previous = try store.fastEvidenceCursor(key: key)
            try source.read { db in
                let maximum = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM logs") ?? 0
                func anchor(_ id: Int64) throws -> String? {
                    try String.fetchOne(db, sql: "SELECT json_array(ts,length(feedback_log_body),substr(feedback_log_body,1,512)) FROM logs WHERE id=?", arguments: [id])
                        .map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
                }
                var start: Int64 = 0
                if let previous, previous.inode == file.inode, previous.device == file.device,
                   previous.lastID <= maximum, try previous.anchor == anchor(previous.lastID) { start = previous.lastID }
                guard start < maximum else { return }
                let threadColumn = try db.columns(in: "logs").contains(where: { $0.name == "thread_id" }) ? "thread_id" : "NULL AS thread_id"
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT id,ts,\(threadColumn),feedback_log_body FROM logs
                    WHERE id > ? AND id <= ? AND length(feedback_log_body) <= 4194304
                      AND (feedback_log_body LIKE '%websocket request:%' OR feedback_log_body LIKE '%Submission sub=Submission {%')
                    ORDER BY id
                    """, arguments: [start, maximum])
                var batch: [Self] = []
                var count = 0
                func commit(_ lastID: Int64) throws {
                    let cursor = Cursor(inode: file.inode, device: file.device, lastID: lastID, anchor: try anchor(lastID))
                    try store.commitFastEvidence(batch, cursor: cursor, key: key)
                    batch.removeAll(keepingCapacity: true)
                }
                while let row = try rows.next() {
                    try autoreleasepool {
                        try Task.checkCancellation()
                        if let body: String = row["feedback_log_body"],
                           let evidence = parse(body: body, threadID: row["thread_id"], fileName: url.lastPathComponent,
                                                rowID: row["id"], timestamp: row["ts"]) { batch.append(evidence) }
                        count += 1
                        if count % 256 == 0 { try commit(row["id"]) }
                    }
                }
                try commit(maximum)
            }
        }
    }
}
