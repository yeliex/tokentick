import Foundation

/// Own the parser and pending batch independently of how source bytes are obtained.
struct RolloutScan {
    private var parser: RolloutParser
    private var usages: [CollectedUsage] = []
    private var limits: [CurrentLimitSnapshot] = []
    private(set) var line: Int
    private(set) var offset: UInt64
    private(set) var pendingLines = 0
    var batchReady: Bool { pendingLines >= 512 }
    var inheritedEvents: Int { parser.inheritedEvents }

    init(identity: RolloutIdentity, cursor: ScanCursor? = nil) {
        parser = RolloutParser(state: cursor?.state ?? RolloutParserState(), identity: identity)
        line = cursor?.line ?? 0
        offset = cursor?.offset ?? 0
    }

    mutating func consume(_ data: Data, endingAt offset: UInt64, report: inout ScanReport) throws {
        let previousState = parser.state
        do {
            if let usage = try parser.consume(data, line: line + 1) { usages.append(usage) }
            if let current = parser.currentLimits {
                if current.windows.contains(where: { $0.durationMinutes == 10_080 }) { limits.append(current) }
                if current.historyExclusion == nil,
                   report.currentLimits.map({ current.observedAt > $0.observedAt }) ?? true { report.currentLimits = current }
            }
            line += 1
            self.offset = offset
            pendingLines += 1
        } catch {
            parser.state = previousState
            throw error
        }
    }

    /// The caller prepares hashes immediately before this transaction. Failed commits keep the pending batch.
    mutating func commit(store: UsageStore, identity: RolloutIdentity, url: URL,
                         checkpoint: FileSnapshot, report: inout ScanReport) throws {
        try store.commitScan(usages, limits: limits, identity: identity, url: url, line: line, offset: offset,
                             file: checkpoint, state: &parser.state, report: &report)
        usages.removeAll(keepingCapacity: true)
        limits.removeAll(keepingCapacity: true)
        pendingLines = 0
    }
}
