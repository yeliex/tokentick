import TokenTickCore
import Darwin
import Foundation

@main
struct TokenTickCommand {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case "help": print(help)
            case "version": print("\(ApplicationInfo.name) \(ApplicationInfo.version)")
            case "scan":
                let store = try UsageStore(databaseURL: options.database)
                let report = try LocalUsageScanner(store: store).scan(codexHome: options.codexHome)
                if options.json { try printJSON(report) }
                else {
                    print("Discovered \(report.discoveredFiles) files; scanned \(report.scannedFiles), unchanged \(report.unchangedFiles).")
                    print("Inserted \(report.insertedRequests) usage events; updated identities/attribution \(report.upgradedRequests), duplicates \(report.duplicateRequests), inherited events \(report.inheritedEvents).")
                    for issue in report.issues {
                        print("\(issue.fileName)\(issue.line.map { ":\($0)" } ?? ""): \(issue.message)")
                    }
                    if report.issueCount > 0 { print("\(report.issueCount) issues in total; showing at most 100.") }
                }
                if report.issueCount > 0 { exit(1) }
            case "sync":
                let store = try UsageStore(databaseURL: options.database)
                let report = try await UsageSynchronizer(store: store).synchronize(scope: options.scope,
                    codexHome: options.codexHome, codexExecutable: options.codexExecutable)
                try printJSON(report)
                if !report.issues.isEmpty { exit(1) }
            case "usage":
                let report = try UsageStore(databaseURL: options.database).usageReport(UsageQuery(
                    grouping: options.grouping, timezone: options.timezone, fromDate: options.fromDate,
                    throughDate: options.throughDate, account: options.account, limit: options.limit, offset: options.offset, filters: options.filters, sort: options.sort))
                if options.json { try printJSON(report) }
                else if report.rows.isEmpty { print("No usage in the selected range.") }
                else {
                    print("Timezone: \(report.timezone); tokens with unknown dates: \(report.unknownDateTokens)")
                    print("Group\tRecords\tTokens\tKnown USD\tUnpriced tokens")
                    for item in report.rows {
                        let amount = item.knownAmountNanoUSD.map { NSDecimalNumber(decimal: Decimal($0) / Decimal(1_000_000_000)).stringValue } ?? "Unknown"
                        print("\(item.group ?? (options.grouping == .total ? "Total" : "Unknown"))\t\(item.records)\t\(item.totalTokens)\t\(amount)\t\(item.unpricedTokens)")
                    }
                }
            case "records":
                try printJSON(UsageStore(databaseURL: options.database).usageRecords(UsageQuery(
                    timezone: options.timezone, fromDate: options.fromDate, throughDate: options.throughDate,
                    account: options.account, limit: options.limit, offset: options.offset, filters: options.filters, sort: options.sort)))
            case "rebuild":
                try printJSON(UsageStore(databaseURL: options.database).rebuildStatistics(timezone: options.timezone))
            case "prices":
                try printJSON(PriceOutput(rows: UsageStore(databaseURL: options.database).priceEntries(limit: options.limit)))
            case "sync-prices":
                let store = try UsageStore(databaseURL: options.database)
                try await printJSON(PriceSynchronizer(store: store).synchronize())
            case "reprice":
                try printJSON(UsageStore(databaseURL: options.database).repriceUsage())
            case "sync-api":
                let store = try UsageStore(databaseURL: options.database)
                let report = try await CodexAPIClient.synchronize(store: store, executable: options.codexExecutable, codexHome: options.codexHome)
                try printJSON(report)
                if report.issue != nil || !report.accountAvailable { exit(1) }
            case "current-limits":
                let store = try UsageStore(databaseURL: options.database)
                let report = try await CodexAPIClient.synchronize(store: store, executable: options.codexExecutable, codexHome: options.codexHome)
                try printJSON(report.currentLimits)
            case "limits":
                try printJSON(UsageStore(databaseURL: options.database).weeklyLimitHistory(LimitQuery(
                    timezone: options.timezone, fromDate: options.fromDate, throughDate: options.throughDate,
                    account: options.account, limitID: options.limitID, limit: options.limit, offset: options.offset)))
            case "api-usage":
                let store = try UsageStore(databaseURL: options.database)
                let report = try await CodexAPIClient.synchronize(store: store, executable: options.codexExecutable, codexHome: options.codexHome)
                try printJSON(APIUsageOutput(rows: store.apiDailyUsage(limit: options.limit)))
                if report.issue != nil { exit(1) }
            case "status": try printJSON(UsageStore(databaseURL: options.database).status())
            default: throw CommandError.invalid("Unsupported command.")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(error is CommandError || error is UsageQueryError ? 2 : 1)
        }
    }

    private struct PriceOutput: Encodable {
        let priceUnit = "USD_per_million_tokens"
        let rows: [PriceEntry]
    }

    private struct APIUsageOutput: Encodable {
        let timezone: String? = nil
        let includedInLocalTotals = false
        let rows: [APIDailyBucket]
        enum CodingKeys: String, CodingKey { case timezone, includedInLocalTotals, rows }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(timezone, forKey: .timezone)
            try values.encode(includedInLocalTotals, forKey: .includedInLocalTotals)
            try values.encode(rows, forKey: .rows)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private enum CommandError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): "\(message) Run tokentick --help for usage." }
        }
    }

    private struct Options {
        var command: String
        var database = UsageStore.defaultDatabaseURL
        var codexHome: URL { LocalUsageScanner.defaultCodexHome }
        var codexExecutable: URL?
        var grouping = UsageGrouping.day
        var scope = SynchronizationScope.all
        var filters = UsageFilters()
        var sort = UsageSort.automatic
        var timezone: String?
        var fromDate: String?
        var throughDate: String?
        var account = UsageAccountScope.all
        var offset = 0
        var limit = 100
        var json = false
        var limitID: String?

        init(arguments: [String]) throws {
            command = arguments.first ?? "help"
            if ["--help", "-h"].contains(command) { command = "help" }
            if command == "--version" { command = "version" }
            guard ["help", "version", "scan", "sync", "usage", "status", "prices", "sync-prices", "reprice", "sync-api", "current-limits", "limits", "api-usage", "rebuild", "records"].contains(command) else {
                throw CommandError.invalid("Unsupported command: \(command).")
            }
            var index = 1
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                if option == "--json" { json = true; continue }
                if option == "--unknown-account", ["usage", "records", "limits"].contains(command) {
                    guard account == .all else { throw CommandError.invalid("Account filters cannot be repeated.") }
                    account = .unknown
                    continue
                }
                if ["usage", "records"].contains(command), ["--unknown-thread", "--unknown-project", "--unknown-model", "--unknown-date"].contains(option) {
                    switch option {
                    case "--unknown-thread": try setFilter(.thread, value: .unknown)
                    case "--unknown-project": try setFilter(.project, value: .unknown)
                    case "--unknown-model": try setFilter(.model, value: .unknown)
                    default: try setFilter(.day, value: .unknown)
                    }
                    continue
                }
                guard index < arguments.count else { throw CommandError.invalid("Missing value for \(option).") }
                let value = arguments[index]
                index += 1
                switch option {
                case "--database": database = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                case "--codex-bin" where ["sync-api", "current-limits", "sync", "api-usage"].contains(command):
                    codexExecutable = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                case "--scope" where command == "sync":
                    guard let scope = SynchronizationScope(rawValue: value) else { throw CommandError.invalid("Sync scope must be all, local, prices, api, or remote.") }
                    self.scope = scope
                case let flag where ["usage", "records"].contains(command) && ["--thread", "--project", "--model", "--day"].contains(flag):
                    switch option {
                    case "--thread": try setFilter(.thread, value: .value(value))
                    case "--project": try setFilter(.project, value: .value(value))
                    case "--model": try setFilter(.model, value: .value(value))
                    default: try setFilter(.day, value: .value(value))
                    }
                case "--search" where ["usage", "records"].contains(command): filters.search = value
                case "--sort" where ["usage", "records"].contains(command):
                    guard let order = UsageSort(rawValue: value) else { throw CommandError.invalid("Sort order must be automatic, tokens, amount, or name.") }
                    sort = order
                case "--limit-id" where command == "limits": limitID = value
                case "--group" where command == "usage":
                    guard let group = UsageGrouping(rawValue: value) else { throw CommandError.invalid("Invalid grouping.") }
                    grouping = group
                case "--timezone" where ["usage", "records", "rebuild", "limits"].contains(command):
                    guard TimeZone(identifier: value) != nil else { throw CommandError.invalid("Invalid IANA timezone.") }
                    timezone = value
                case "--from" where ["usage", "records", "limits"].contains(command): fromDate = value
                case "--through" where ["usage", "records", "limits"].contains(command): throughDate = value
                case "--account" where ["usage", "records", "limits"].contains(command):
                    guard account == .all, !value.isEmpty else { throw CommandError.invalid("Account filters cannot be repeated or empty.") }
                    account = .account(value)
                case "--offset" where ["usage", "records", "limits"].contains(command):
                    guard let count = Int(value), count >= 0 else { throw CommandError.invalid("offset cannot be negative.") }
                    offset = count
                case "--limit" where ["usage", "records", "prices", "limits", "api-usage"].contains(command):
                    guard let count = Int(value), (1...10_000).contains(count) else { throw CommandError.invalid("limit must be 1–10000.") }
                    limit = count
                default: throw CommandError.invalid("Unsupported option: \(option).")
                }
            }
        }

        private mutating func setFilter(_ grouping: UsageGrouping, value: UsageValueFilter) throws {
            let key: WritableKeyPath<UsageFilters, UsageValueFilter>
            switch grouping {
            case .thread: key = \.thread
            case .project: key = \.project
            case .model: key = \.model
            default: key = \.day
            }
            guard filters[keyPath: key] == .all else { throw CommandError.invalid("Filters for the same dimension cannot be repeated.") }
            filters[keyPath: key] = value
        }
    }

    private static let help = """
    TokenTick — Codex usage and cost tracking

    Usage: tokentick <command> [options]

      scan          Collect sessions and archived_sessions incrementally (including .jsonl.zst)
      sync          Sync sources and statistics; --scope all|local|prices|api|remote
      usage         Query usage; --group total|day|thread|project|model, --limit 100
      records       Read paginated usage events and source evidence (JSON)
      rebuild       Rebuild statistics; --timezone Asia/Shanghai
      prices        Read historical prices (JSON), --limit 100
      sync-prices   Fetch models.dev prices (one successful refresh per day)
      reprice       Recalculate costs using prices for each usage date
      sync-api      Refresh API data and update completed weekly cycles
      api-usage     Fetch daily totals and in-memory reference differences
      limits        Read completed weekly windows and their last observed percentages
      current-limits Fetch all current limits (JSON)
      status        Read source status, timezone, fact/cache revisions, and row counts
      --version     Show version
      --help        Show help

    Common options: --database <SQLite path>, --json
    Codex directory: current CODEX_HOME, falling back to ~/.codex.
    sync-api/current-limits/sync/api-usage: --codex-bin <Codex executable path>
    usage/records: --from YYYY-MM-DD --through YYYY-MM-DD (inclusive)
                  --timezone <IANA timezone> --offset 0
                  --account <account ID> or --unknown-account
    Combined filters: --thread <ID> --project <name> --model <model> --day YYYY-MM-DD
                  --search <task title or ID> --sort automatic|tokens|amount|name
    Unknown values: --unknown-thread/--unknown-project/--unknown-model/--unknown-date
    Filters intersect. Each dimension can be specified once. Sorting precedes pagination.
    limits: --from YYYY-MM-DD --through YYYY-MM-DD --timezone <IANA timezone>
            --account <account ID> or --unknown-account, --limit-id <limit bucket>
            --limit 100 --offset 0
    Limit dates filter observed weekly resets; percentages do not determine tokens or costs.
    scan exits with 1 on parsing issues; invalid arguments exit with 2.
    Bundled prices cover missing database prices. Unobserved tiers use standard rates;
    unknown models or required rates remain null. Known Fast never falls back to standard.
    Costs are API-equivalent estimates in nanoUSD (1 USD = 10^9 nanoUSD).
    """
}
