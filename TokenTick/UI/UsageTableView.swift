import SwiftUI
import TokenTickCore

struct UsageTableView: View {
    let rows: [UsageDisplayRow]
    let isThread: Bool
    let hasMore: Bool
    let totalGroups: Int
    @Binding var selection: String?
    @Binding var page: Int
    var openRow: (UsageDisplayRow) -> Void
    var showDetails: (UsageDisplayRow) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn(isThread ? String(localized: "Task") : String(localized: "Name")) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Button { openRow(row) } label: {
                            HStack {
                                Text(row.title).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if isThread { Text(UsageFormatting.project(row.thread?.projectName)).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 7).help(row.title)
                }.width(min: 180, ideal: 340)
                TableColumn("Tokens") { row in TokenText(value: row.summary.totalTokens).monospacedDigit() }
                    .width(min: 105, ideal: 125)
                TableColumn(String(localized: "Estimated cost")) { row in Text(UsageFormatting.money(row.summary.knownAmountNanoUSD)).monospacedDigit()
                    .help(row.summary.unpricedTokens > 0 ? String(localized: "Some usage is unpriced") : String(localized: "Estimated using public API prices")) }
                    .width(min: 90, ideal: 110)
                TableColumn(String(localized: "Requests")) { row in Text(row.summary.records.formatted()).monospacedDigit() }
                    .width(min: 75, ideal: 90)

                TableColumn(String(localized: "Details")) { row in
                    Button(String(localized: "Details")) { showDetails(row) }.buttonStyle(.borderless)
                }.width(50)
            }.tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text(String(localized: "Page \(totalGroups == 0 ? 0 : page + 1) of \((totalGroups + 99) / 100) · Total: \(totalGroups)")).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Previous")) { selection = nil; page -= 1 }.disabled(page == 0)
                Button(String(localized: "Next")) { selection = nil; page += 1 }.disabled(!hasMore)
            }.padding(12)
        }
    }
}
