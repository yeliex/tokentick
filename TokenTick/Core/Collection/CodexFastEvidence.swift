import Foundation

/// Cache only Fast evidence needed for statistics, not request bodies from traces.
struct CodexFastEvidence: Codable, Sendable {
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
            // A ThreadSettings submission ID is not a turn ID; accept only actual turn submissions.
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

    struct Cursor: Codable, Sendable, Equatable {
        let inode: UInt64
        let device: UInt64
        let lastID: Int64
        let anchor: String?
    }

}
