import Foundation
import SwiftUI

enum UsageFormatting {
    static func project(_ name: String?) -> String { name == "Chat" ? "无项目聊天" : name ?? "未知归属" }
    static func tokens(_ value: Int64?) -> String {
        value.map { $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))) } ?? "—"
    }
    static func exactTokens(_ value: Int64?) -> String { value.map { $0.formatted() } ?? "未知" }
    static func money(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(value) / Decimal(1_000_000_000))) ?? "—"
    }
    static func exactMoney(_ value: Int64?) -> String {
        value.map { "$" + NSDecimalNumber(decimal: Decimal($0) / Decimal(1_000_000_000)).stringValue } ?? "未知"
    }
    static func timestamp(_ value: Double?, timezone: TimeZone = .current) -> String {
        value.map { Date(timeIntervalSince1970: $0).formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: timezone)) } ?? "尚未记录"
    }
}

struct TokenText: View {
    let value: Int64?
    var body: some View {
        Text(UsageFormatting.tokens(value)).monospacedDigit()
            .help(UsageFormatting.exactTokens(value))
            .accessibilityLabel(UsageFormatting.exactTokens(value))
    }
}
