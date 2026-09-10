import Foundation

public struct CurrentLimitSnapshot: Codable, Sendable {
    public let accountID: String?
    public let observedAt: Double
    public let source: String
    public let scopeKey: String
    public let windows: [CurrentLimitWindow]
    public let sourceJSON: String
    public var fileName: String? = nil
    public var line: Int? = nil

    static func log(raw: SourceJSON, observedAt: Double, threadID: String, fileName: String, line: Int) throws -> Self {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(raw)
        var result = try parse(data, accountID: nil, observedAt: observedAt, source: "local", scopeKey: "thread:" + threadID, snakeCase: true)
        result.fileName = fileName; result.line = line
        return result
    }

    static func parse(_ data: Data, accountID: String?, observedAt: Double, source: String, scopeKey: String, snakeCase: Bool = false) throws -> Self {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], observedAt.isFinite else {
            throw CodexAPIError.invalidStatistics
        }
        let buckets: [String: Any]
        if snakeCase { buckets = [(raw["limit_id"] as? String) ?? "codex": raw] }
        else if let mapped = raw["rateLimitsByLimitId"] as? [String: Any] { buckets = mapped }
        else if let single = raw["rateLimits"] as? [String: Any] { buckets = [(single["limitId"] as? String) ?? "codex": single] }
        else { buckets = [:] }
        var windows: [CurrentLimitWindow] = []
        for (id, value) in buckets.sorted(by: { $0.key < $1.key }) {
            guard let bucket = value as? [String: Any] else { continue }
            for kind in ["primary", "secondary"] {
                guard let window = bucket[kind] as? [String: Any],
                      let percent = window[snakeCase ? "used_percent" : "usedPercent"] as? Double,
                      percent.isFinite, percent >= 0 else { continue }
                windows.append(CurrentLimitWindow(limitID: id, kind: kind, usedPercent: percent,
                    durationMinutes: (window[snakeCase ? "window_minutes" : "windowDurationMins"] as? NSNumber)?.int64Value,
                    resetsAt: (window[snakeCase ? "resets_at" : "resetsAt"] as? NSNumber)?.int64Value))
            }
        }
        return Self(accountID: accountID, observedAt: observedAt, source: source, scopeKey: scopeKey,
                    windows: windows, sourceJSON: String(decoding: data, as: UTF8.self))
    }
}

public struct CurrentLimitWindow: Codable, Sendable, Identifiable {
    public var id: String { limitID + ":" + kind }
    public let limitID: String
    public let kind: String
    public let usedPercent: Double
    public let durationMinutes: Int64?
    public let resetsAt: Int64?
}
