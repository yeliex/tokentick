import Foundation
import Testing
@testable import TokenTickCore

struct RemoteSyncScheduleTests {
    @Test func waitingDevicesPrecedeRepeatedBackfill() {
        let devices = (0..<4).map { RemoteDevice(name: "Device \($0)", connection: .directory(path: "/fixture/\($0)", bookmark: nil)) }
        let now = Date(timeIntervalSince1970: 1_000)
        var schedules: [String: RemoteSyncSchedule] = [:]
        #expect(RemoteSyncSchedule.dueDevices(devices, schedules: schedules, running: [], at: now).map(\.id) == devices.map(\.id))
        var report = ScanReport()
        report.pendingFiles = 100
        for device in devices.prefix(2) { schedules[device.id, default: RemoteSyncSchedule()].received(report, at: now) }
        let later = now.addingTimeInterval(60)
        #expect(RemoteSyncSchedule.dueDevices(devices, schedules: schedules, running: [], at: later).map(\.id) == [devices[2], devices[3], devices[0], devices[1]].map(\.id))
        #expect(RemoteSyncSchedule.dueDevices(devices, schedules: schedules, running: [devices[0].id], at: later).map(\.id) == [devices[2], devices[3], devices[1]].map(\.id))
        #expect(RemoteSyncSchedule.dueDevices(devices, schedules: schedules, running: [devices[0].id, devices[1].id], at: later).map(\.id) == Array(devices.suffix(2)).map(\.id))
        schedules[devices[2].id, default: RemoteSyncSchedule()].failed(at: now, jitter: 0)
        var paused = devices
        paused[3].enabled = false
        #expect(RemoteSyncSchedule.dueDevices(paused, schedules: schedules, running: [], at: later).map(\.id) == Array(devices.prefix(2)).map(\.id))
    }

    @Test func backfillContinuesPromptlyUnlessReadingFailed() {
        let now = Date(timeIntervalSince1970: 1_000)
        var schedule = RemoteSyncSchedule()
        var report = ScanReport()
        report.pendingFiles = 10
        schedule.received(report, at: now)
        #expect(schedule.nextCheck == now.addingTimeInterval(30))
        report.pendingFiles = 0
        report.pendingMetadata = true
        schedule.received(report, at: now)
        #expect(schedule.nextCheck == now.addingTimeInterval(30))
        report.addIssue("device_read", ScanIssue(fileName: "rollout.jsonl", line: nil, message: "Unavailable"))
        schedule.received(report, at: now)
        #expect(schedule.failures == 1 && schedule.nextCheck >= now.addingTimeInterval(300))
    }

    @Test func optionalMetadataFailuresDoNotBackOffReadableLogs() {
        let now = Date(timeIntervalSince1970: 1_000)
        var schedule = RemoteSyncSchedule()
        var report = ScanReport()
        report.scannedFiles = 1
        report.addIssue("catalog", ScanIssue(fileName: "state_5.sqlite", line: nil, message: "Unavailable"))
        report.addIssue("traces", ScanIssue(fileName: "logs_2.sqlite", line: nil, message: "Unsupported"))
        schedule.received(report, at: now)
        #expect(schedule.failures == 0 && schedule.nextCheck == now.addingTimeInterval(120))
        report.addIssue("device_read", ScanIssue(fileName: "rollout.jsonl", line: nil, message: "Unavailable"))
        schedule.received(report, at: now)
        #expect(schedule.failures == 1 && schedule.nextCheck >= now.addingTimeInterval(300))
    }

    @Test func unchangedFilesBackOffAndChangesRestoreFrequency() {
        let now = Date(timeIntervalSince1970: 1_000)
        var schedule = RemoteSyncSchedule()
        #expect(schedule.isDue(at: now))
        for minutes in [5, 15, 30, 30] {
            schedule.completed(at: now, changed: false)
            #expect(schedule.nextCheck == now.addingTimeInterval(Double(minutes * 60)))
        }
        schedule.completed(at: now, changed: true)
        #expect(schedule.nextCheck == now.addingTimeInterval(120))
    }

    @Test func failuresBackOffIndependentlyAndRecover() {
        let now = Date(timeIntervalSince1970: 1_000)
        var schedule = RemoteSyncSchedule()
        for minutes in [5, 15, 30, 60, 60] {
            schedule.failed(at: now, jitter: 0)
            #expect(schedule.nextCheck == now.addingTimeInterval(Double(minutes * 60)))
        }
        schedule.completed(at: now, changed: true)
        #expect(schedule.failures == 0)
        #expect(schedule.nextCheck == now.addingTimeInterval(120))
    }
}
