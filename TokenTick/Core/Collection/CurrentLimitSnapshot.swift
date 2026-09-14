import Foundation

public struct CurrentLimitSnapshot: Codable, Sendable {
    public let accountID: String?
    public let observedAt: Double
    public let source: String
    public let scopeKey: String
    public let windows: [CurrentLimitWindow]
    public let sourceJSON: String
    public var planType: String? = nil
    public var availableResets: Int64? = nil
    public var resetCreditExpirations: [Int64?]? = nil
    public var creditsBalance: String? = nil
    public var unlimitedCredits: Bool? = nil
    public var fileName: String? = nil
    public var line: Int? = nil
    public var turnID: String? = nil
    public var historyExclusion: String? = nil

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
                    resetsAt: (window[snakeCase ? "resets_at" : "resetsAt"] as? NSNumber)?.int64Value,
                    displayName: bucket[snakeCase ? "limit_name" : "limitName"] as? String))
            }
        }
        var result = Self(accountID: accountID, observedAt: observedAt, source: source, scopeKey: scopeKey,
                    windows: windows, sourceJSON: String(decoding: data, as: UTF8.self))
        let main = buckets["codex"] as? [String: Any] ?? raw["rateLimits"] as? [String: Any]
        result.planType = main?[snakeCase ? "plan_type" : "planType"] as? String
        if let resets = raw["rateLimitResetCredits"] as? [String: Any],
           let count = resets["availableCount"] as? Int64, count >= 0 {
            result.availableResets = count
            if count > 0, let credits = resets["credits"] as? [[String: Any]] {
                // 明细可能少于总次数；保留每次重置的到期时间，nil 表示接口明确返回永不过期。
                result.resetCreditExpirations = credits.filter { credit in
                    guard credit["status"] as? String == "available",
                          credit["resetType"] as? String == "codexRateLimits" else { return false }
                    return credit["expiresAt"] is NSNull
                        || (credit["expiresAt"] as? Int64).map { Double($0) > observedAt } == true
                }.map { $0["expiresAt"] as? Int64 }.sorted { ($0 ?? .max) < ($1 ?? .max) }
            }
        }
        if let credits = main?["credits"] as? [String: Any] {
            result.creditsBalance = credits["balance"] as? String
            result.unlimitedCredits = credits["unlimited"] as? Bool
        }
        return result
    }
}

public struct CurrentLimitWindow: Codable, Sendable, Identifiable {
    public var id: String { limitID + ":" + kind }
    public let limitID: String
    public let kind: String
    public let usedPercent: Double
    public let durationMinutes: Int64?
    public let resetsAt: Int64?
    public var displayName: String? = nil
}
