import SwiftUI
import TokenTickCore

struct DataStatusView: View {
    @Environment(ApplicationModel.self) private var app
    var body: some View {
        Group {
            Section(String(localized: "Sync")) {
                if app.isSyncing {
                    LabeledContent(String(localized: "Syncing"), value: app.progressText)
                } else {
                    LabeledContent(String(localized: "Last sync"), value: UsageFormatting.timestamp(app.lastSync?.finishedAt))
                }
                if let issue = app.automaticSyncIssue {
                    Text(issue).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let error = app.error {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent(String(localized: "Requests"), value: app.status?.tables["usage"].map { $0.formatted() } ?? "—")
                LabeledContent(String(localized: "Conversations"), value: app.status?.tables["threads"].map { $0.formatted() } ?? "—")
                Button(app.isSyncing ? String(localized: "Cancel sync") : String(localized: "Refresh")) {
                    if app.isSyncing { app.cancelSync() }
                    else { app.synchronize() }
                }.disabled(app.isSyncing && app.progress?.stage == .statistics)
                if let scan = app.lastSync?.scan, scan.issueCount > 0 {
                    ForEach(Array(scan.issues.enumerated()), id: \.offset) { _, issue in
                        Text("\(issue.fileName): \(issue.message)").font(.caption).textSelection(.enabled)
                    }
                }
            }
            Section(String(localized: "Model prices")) {
                LabeledContent(String(localized: "Last synced date"), value: app.status?.priceLastSuccessDate ?? String(localized: "Not synced yet"))
                Button(String(localized: "Sync prices and recalculate historical costs")) { app.synchronize(.prices) }.disabled(app.isSyncing)
            }
            Section(String(localized: "Server statistics")) {
                if let report = app.status?.apiLastReport {
                    LabeledContent(String(localized: "Last request"), value: UsageFormatting.timestamp(report.observedAt))
                    LabeledContent(String(localized: "Subscription account"), value: report.accountEmail ?? String(localized: "Unavailable")).textSelection(.enabled)
                    if let issue = report.issue {
                        Label(issue, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                    }
                }
                Button(String(localized: "Refresh")) { app.synchronize(.api) }.disabled(app.isSyncing)
            }
            if let sync = app.lastSync, !sync.issues.isEmpty {
                Section(String(localized: "Recent sync issues")) {
                    ForEach(Array(sync.issues.enumerated()), id: \.offset) { _, message in Text(message).textSelection(.enabled) }
                }
            }
        }
    }
}
