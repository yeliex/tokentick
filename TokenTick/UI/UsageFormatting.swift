import Foundation
import TokenTickCore

enum UsageFormatting {
    static func tokens(_ value: Int64?) -> String { value.map { $0.formatted() } ?? "—" }
    static func money(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(value) / Decimal(1_000_000_000))) ?? "—"
    }
    static func timestamp(_ value: Double?) -> String {
        value.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "尚未记录"
    }
}
