import Foundation

extension CurrentLimitWindow {
    public func usageTicks(workingDays: Int) -> [Double] {
        guard durationMinutes != 300 else { return [] }
        let days = durationMinutes == 10080 ? ([4, 5, 7].contains(workingDays) ? workingDays : 5)
            : min(90, Int((durationMinutes ?? 0) / 1440))
        let daily = days > 1 ? (1..<days).map { Double($0) * 100 / Double(days) } : []
        return Array(Set(daily + [50, 80])).sorted()
    }

    public func expectedUsedPercent(now: Double) -> Double? {
        guard now.isFinite, let reset = resetsAt, let minutes = durationMinutes, minutes > 0 else { return nil }
        let duration = Double(minutes) * 60
        let start = Double(reset) - duration
        guard now >= start, now < Double(reset) else { return nil }
        return (now - start) / duration * 100
    }
}
