import SwiftUI
import TokenTickCore

extension UsageSort {
    var title: String {
        switch self {
        case .automatic: String(localized: "Default order")
        case .tokens: String(localized: "Tokens, highest first")
        case .amount: String(localized: "Known cost, highest first")
        case .name: String(localized: "Name, ascending")
        }
    }
}

extension UsageFilters {
    var summary: String {
        [(String(localized: "Task"), thread), (String(localized: "Project"), project), (String(localized: "Model"), model), (String(localized: "Day"), day)].enumerated().compactMap { index, entry in
            let (name, filter) = entry
            return switch filter {
            case .all: nil
            case .unknown: String(localized: "\(name): Unknown")
            case .value(let value): String(localized: "\(name): \(index == 1 ? UsageFormatting.project(value) : value)")
            }
        }.joined(separator: " · ")
    }
}

struct UsageDateFilter: View {
    @Binding var period: UsagePeriod
    @Binding var from: Date
    @Binding var through: Date
    let periods: [UsagePeriod]
    let timezone: TimeZone
    @State private var showingCalendar = false
    @State private var draftFrom = Date()
    @State private var draftThrough = Date()

    var body: some View {
        Menu {
            ForEach(periods) { value in
                Button { period = value } label: {
                    if period == value { Label(value.title, systemImage: "checkmark") }
                    else { Text(value.title) }
                }
            }
            Divider()
            Button(String(localized: "Custom…")) { openCalendar() }
        } label: {
            Text(period.title)
        }.frame(width: 90).accessibilityLabel(String(localized: "Date range"))
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "Choose date range")).font(.headline)
                DatePicker(String(localized: "Start date"), selection: $draftFrom, in: ...draftThrough, displayedComponents: .date)
                DatePicker(String(localized: "End date"), selection: $draftThrough, in: draftFrom..., displayedComponents: .date)
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { showingCalendar = false }.keyboardShortcut(.cancelAction)
                    Button(String(localized: "Apply")) {
                        from = draftFrom; through = draftThrough; period = .custom
                        showingCalendar = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.environment(\.timeZone, timezone).padding(24).frame(width: 380)
        }
    }

    private func openCalendar() {
        if period == .custom { draftFrom = from; draftThrough = through }
        else {
            let dates = period.dates(timezone: timezone)
            let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
            draftFrom = dates.0.flatMap { try? style.parse($0) } ?? from
            draftThrough = dates.1.flatMap { try? style.parse($0) } ?? through
        }
        showingCalendar = true
    }
}
