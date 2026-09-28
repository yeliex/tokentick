import Foundation

/// Per-device polling backs off after unchanged results or connection failures.
public struct RemoteSyncSchedule: Sendable {
    public private(set) var nextCheck: Date = .distantPast
    public private(set) var unchangedChecks = 0
    public private(set) var failures = 0

    public init() {}

    public func isDue(at now: Date) -> Bool { now >= nextCheck }

    public static func dueDevices(_ devices: [RemoteDevice], schedules: [String: Self],
                                  running: Set<String>, at now: Date) -> [RemoteDevice] {
        // A busy early entry must not repeatedly overtake devices that have waited longer.
        return devices.enumerated().filter { _, device in
            device.enabled && !running.contains(device.id)
                && (schedules[device.id]?.isDue(at: now) ?? true)
        }.sorted { lhs, rhs in
            let first = schedules[lhs.element.id]?.nextCheck ?? .distantPast
            let second = schedules[rhs.element.id]?.nextCheck ?? .distantPast
            return first == second ? lhs.offset < rhs.offset : first < second
        }.map(\.element)
    }

    public mutating func received(_ report: ScanReport, at now: Date) {
        // Optional catalogs and trace capabilities do not make a readable log source offline.
        if (report.diagnosticCounts["device_read"] ?? 0) > 0 { failed(at: now) }
        else if report.pendingFiles > 0 || report.pendingMetadata {
            failures = 0
            unchangedChecks = 0
            nextCheck = now.addingTimeInterval(30)
        }
        else { completed(at: now, changed: report.scannedFiles > 0) }
    }

    public mutating func completed(at now: Date, changed: Bool) {
        failures = 0
        if changed { unchangedChecks = 0 }
        else { unchangedChecks = min(unchangedChecks + 1, 3) }
        let minutes = [2, 5, 15, 30][unchangedChecks]
        nextCheck = now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    public mutating func failed(at now: Date, jitter: Double = Double.random(in: 0...0.1)) {
        failures = min(failures + 1, 4)
        let minutes = [5, 15, 30, 60][failures - 1]
        nextCheck = now.addingTimeInterval(TimeInterval(minutes * 60) * (1 + min(max(jitter, 0), 0.1)))
    }

    public mutating func requestRefresh(at now: Date) {
        nextCheck = min(nextCheck, now)
    }
}
