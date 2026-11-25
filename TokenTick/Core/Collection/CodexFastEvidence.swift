import Foundation

/// Cache only the normalized tier and matching identifiers, never request bodies.
struct CodexFastEvidence: Sendable {
    let threadID: String
    let turnID: String
    let kind: String
    let tier: String
    let responseID: String?

    func key(device: String) -> String {
        "tier_trace:\(device):\(threadID):\(turnID):\(responseID ?? "")"
    }

    var strength: Int { kind == "response" ? 3 : (kind == "turn_submission" ? 1 : 2) }

    static func parse(body: String, threadID: String?) -> Self? {
        let thread: String?
        let turn: String?
        let kind: String
        let rawTier: String?
        let responseID: String?
        if let marker = body.range(of: "websocket event:") {
            let prefix = String(body[..<marker.lowerBound])
            guard let event = (try? JSONSerialization.jsonObject(with: Data(body[marker.upperBound...].utf8))) as? [String: Any],
                  event["type"] as? String == "response.completed",
                  let response = event["response"] as? [String: Any],
                  let id = response["id"] as? String, !id.isEmpty else { return nil }
            thread = value("thread_id", in: prefix) ?? threadID
            turn = value("turn.id", in: prefix) ?? value("turn_id", in: prefix)
            rawTier = response["service_tier"] as? String
            responseID = id
            kind = "response"
        } else if let marker = body.range(of: "websocket request:") {
            let prefix = String(body[..<marker.lowerBound])
            guard let request = (try? JSONSerialization.jsonObject(with: Data(body[marker.upperBound...].utf8))) as? [String: Any],
                  request["type"] as? String == "response.create",
                  request["generate"] as? Bool != false else { return nil }
            thread = value("thread_id", in: prefix) ?? threadID
            turn = value("turn.id", in: prefix) ?? value("turn_id", in: prefix) ?? request["turn_id"] as? String
            rawTier = request["service_tier"] as? String
            responseID = value("response_id", in: prefix)
            kind = "websocket_request"
        } else if let marker = body.range(of: "tags_json=") {
            let prefix = String(body[..<marker.lowerBound])
            guard prefix.contains("run_sampling_request{"),
                  let tags = (try? JSONSerialization.jsonObject(with: Data(body[marker.upperBound...].utf8))) as? [String: Any] else { return nil }
            thread = value("thread_id", in: prefix) ?? threadID
            turn = value("turn.id", in: prefix) ?? value("turn_id", in: prefix)
            rawTier = tags["service_tier"] as? String
            responseID = value("response_id", in: prefix)
            kind = "sampling_request"
        } else if let marker = body.range(of: "Submission sub=Submission {") {
            let prefix = String(body[..<marker.lowerBound])
            let submission = String(body[marker.upperBound...])
            // A ThreadSettings submission ID is not a turn ID; accept only actual turn submissions.
            guard submission.range(of: #"^\s*id: "[^"]+", op: (TurnInput|UserInput) \{"#, options: .regularExpression) != nil else { return nil }
            let pattern = #"service_tier:\s*Some\(Some\("[a-z_]+"\)\)"#
            guard let match = submission.range(of: pattern, options: .regularExpression),
                  !insideQuotedString(submission[..<match.lowerBound]) else { return nil }
            thread = value("thread_id", in: prefix) ?? threadID
            turn = submission.components(separatedBy: "id: \"").dropFirst().first?.components(separatedBy: "\"").first
            rawTier = submission[match].split(separator: "\"").dropFirst().first.map(String.init)
            responseID = nil
            kind = "turn_submission"
        } else { return nil }
        guard let tier = CodexServiceTier.normalized(rawTier), tier != "auto",
              let thread, let turn, let threadUUID = UUID(uuidString: thread), let turnUUID = UUID(uuidString: turn),
              threadID == nil || threadID?.lowercased() == threadUUID.uuidString.lowercased() else { return nil }
        return Self(threadID: threadUUID.uuidString.lowercased(), turnID: turnUUID.uuidString.lowercased(),
                    kind: kind, tier: tier, responseID: responseID)
    }

    private static func value(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "(?<![a-zA-Z0-9_])" + NSRegularExpression.escapedPattern(for: name) + "=", options: .regularExpression) else { return nil }
        let tail = text[range.upperBound...]
        let value = tail.first == "\"" ? tail.dropFirst() : tail
        return String(value.prefix { !$0.isWhitespace && !",]}):\"".contains($0) })
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
