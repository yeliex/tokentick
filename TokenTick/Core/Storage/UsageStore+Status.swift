import Foundation
import GRDB

public struct StoreStatus: Codable, Sendable {
    public let tables: [String: Int]
    public let timezone: String
    public let factsRevision: Int64
    public let cacheRevision: Int64?
    public let cacheCurrent: Bool
    public let cacheRows: Int
    public let lastFileScanAt: Double?
    public let priceLastSuccessDate: String?
    public let apiLastReport: APISyncReport?

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tables, forKey: .tables)
        try values.encode(timezone, forKey: .timezone)
        try values.encode(factsRevision, forKey: .factsRevision)
        try values.encode(cacheRevision, forKey: .cacheRevision)
        try values.encode(cacheCurrent, forKey: .cacheCurrent)
        try values.encode(cacheRows, forKey: .cacheRows)
        try values.encode(lastFileScanAt, forKey: .lastFileScanAt)
        try values.encode(priceLastSuccessDate, forKey: .priceLastSuccessDate)
        try values.encode(apiLastReport, forKey: .apiLastReport)
    }
}

extension UsageStore {
    public func status() throws -> StoreStatus {
        try pool.read { db in
            var counts: [String: Int] = [:]
            for table in StoreSchema.tables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            let timezone = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'statistics_timezone'") ?? "UTC"
            let revision = try Self.statisticsRevision(db)
            let cached = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_metadata WHERE key = ?",
                                           arguments: ["statistics_cache_revision:\(timezone)"])
            let report = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'api_last_report'")
                .map { try JSONDecoder().decode(APISyncReport.self, from: Data($0.utf8)) }
            return StoreStatus(tables: counts, timezone: timezone, factsRevision: revision, cacheRevision: cached,
                               cacheCurrent: cached == revision,
                               cacheRows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM statistics WHERE timezone = ?", arguments: [timezone]) ?? 0,
                               lastFileScanAt: try Double.fetchOne(db, sql: "SELECT MAX(last_scanned_at) FROM scan_files"),
                               priceLastSuccessDate: try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'prices_last_success_date'"),
                               apiLastReport: report)
        }
    }
}
