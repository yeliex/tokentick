import TokenTickCore
import Foundation
import SwiftUI

enum UsageFormatting {
    static func project(_ name: String?) -> String { name == "Chat" ? String(localized: "Chat") : name ?? String(localized: "Unattributed") }
    static func tokens(_ value: Int64?) -> String {
        value.map { $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))) } ?? "—"
    }
    static func exactTokens(_ value: Int64?) -> String { value.map { $0.formatted() } ?? String(localized: "Unknown") }
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
        value.map { "$" + NSDecimalNumber(decimal: Decimal($0) / Decimal(1_000_000_000)).stringValue } ?? String(localized: "Unknown")
    }
    static func timestamp(_ value: Double?, timezone: TimeZone = .current) -> String {
        value.map { Date(timeIntervalSince1970: $0).formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: timezone)) } ?? String(localized: "Not recorded yet")
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

extension OverviewPeriod {

    var title: String {
        switch self {
        case .day: String(localized: "Today")
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        case .quarter: String(localized: "90 days")
        case .year: String(localized: "1 year")
        case .all: String(localized: "Lifetime")
        }
    }
}
