import Foundation
import Observation
import Network
import TokenTickCore

@MainActor @Observable
final class RemoteDevicesModel {
    struct Status {
        var busy = false
        var testing = false
        var progress: ScanProgress?
        var result: DeviceSyncResult?
        var error: String?
        var connectionTest: DeviceConnectionTestResult?
        var connectionTestError: String?
    }

    private(set) var configuration = DeviceConfiguration()
    private(set) var collectionDates: [String: Date] = [:]

    func refreshCollectionDates() async {
        guard let service else { return }
        let snapshot = configuration
        do {
            let dates = try await Task.detached(priority: .utility) {
                try service.store.deviceCollectionDates(snapshot)
            }.value
            guard snapshot == configuration, !Task.isCancelled else { return }
            collectionDates = dates
        } catch { self.error = error.localizedDescription }
    }
    private(set) var statuses: [String: Status] = [:]
    var error: String?
    @ObservationIgnored private var service: DeviceSyncService?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var schedules: [String: RemoteSyncSchedule] = [:]
    @ObservationIgnored private var metadataRefreshedAt: [String: Date] = [:]
    @ObservationIgnored private var editingIDs = Set<String>()
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var collectionPaused = false
    @ObservationIgnored private var networkAvailable: Bool?
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var onChange: (@MainActor () async -> Void)?

    func start(store: UsageStore, onChange: @escaping @MainActor () async -> Void) {
        guard service == nil, let executable = Bundle.main.executableURL else { return }
        service = DeviceSyncService(store: store, executable: executable)
        self.onChange = onChange
        reload()
    }

    private func updateMonitoring() {
        guard configuration.devices.contains(where: \.enabled),
              ProcessInfo.processInfo.environment["TOKENTICK_AUTOSYNC"] != "0" else {
            timer?.cancel(); timer = nil
            networkMonitor?.cancel(); networkMonitor = nil
            networkAvailable = nil
            recovery?.cancel(); recovery = nil
            return
        }
        guard timer == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let previous = self.networkAvailable
                self.networkAvailable = available
                if previous == false && available && !self.suspended { self.recovered() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "TokenTick.remote-network"))
        networkMonitor = monitor
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    func suspend() {
        suspended = true
        recovery?.cancel()
        recovery = nil
        for task in tasks.values { task.cancel() }
    }

    func pauseCollection() async {
        collectionPaused = true
        let active = Array(tasks.values)
        for id in Set(tasks.keys) {
            schedules[id, default: RemoteSyncSchedule()].requestRefresh(at: Date())
        }
        for task in active { task.cancel() }
        for task in active { await task.value }
    }

    func resumeCollection() {
        collectionPaused = false
        tick()
    }

    func recovered() {
        suspended = false
        guard configuration.devices.contains(where: \.enabled) else { return }
        // Wake and network notifications often arrive together; one scan uses current state.
        recovery?.cancel()
        recovery = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !self.suspended else { return }
            self.reload()
            for device in self.configuration.devices where device.enabled {
                self.schedules[device.id, default: RemoteSyncSchedule()].requestRefresh(at: Date())
            }
            self.tick()
            self.recovery = nil
        }
    }

    func name(_ id: String) -> String {
        if id == "local" { return String(localized: "Local") }
        if let device = configuration.devices.first(where: { $0.id == id }) { return device.name }
        if let name = configuration.removedNames[id] { return String(localized: "\(name) (removed)") }
        return id
    }

    func reload() {
        guard let service else { return }
        do {
            let loaded = try service.configurations.load()
            if loaded != configuration {
                for previous in configuration.devices {
                    let next = loaded.devices.first { $0.id == previous.id }
                    guard next == nil || next?.connection != previous.connection
                        || next?.sourceRevision != previous.sourceRevision || next?.enabled != previous.enabled else { continue }
                    generations[previous.id] = nil
                    tasks[previous.id]?.cancel()
                        statuses[previous.id] = nil
                    schedules[previous.id] = nil
                    metadataRefreshedAt[previous.id] = nil
                }
                configuration = loaded
                Task { await refreshCollectionDates() }
            }
            updateMonitoring()
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }

    func run(_ device: RemoteDevice, refreshMetadata: Bool = true) {
        guard !suspended, !collectionPaused, tasks[device.id] == nil, !editingIDs.contains(device.id), let service else { return }
        let previous = statuses[device.id] ?? Status()
        let generation = UUID()
        generations[device.id] = generation
        var status = previous
        status.busy = true; status.testing = false; status.error = nil; status.progress = nil
        status.connectionTest = nil; status.connectionTestError = nil
        statuses[device.id] = status
        tasks[device.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.tasks[device.id] = nil
                self.generations[device.id] = nil
            }
            do {
                var result = try await service.synchronize(device, refreshMetadata: refreshMetadata, onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard self?.generations[device.id] == generation else { return }
                        self?.statuses[device.id]?.progress = progress
                    }
                })
                try Task.checkCancellation()
                guard self.generations[device.id] == generation else { return }
                if result.metadataRefreshed { self.metadataRefreshedAt[device.id] = result.finishedAt }
                else { result.accountEmail = previous.result?.accountEmail }
                var finished = Status()
                finished.result = result
                self.statuses[device.id] = finished
                await self.refreshCollectionDates()
                var schedule = self.schedules[device.id] ?? RemoteSyncSchedule()
                if let report = result.scan { schedule.received(report, at: Date()) }
                self.schedules[device.id] = schedule
                if result.dataChanged || previous.result == nil { await self.onChange?() }
            } catch is CancellationError {
                if self.generations[device.id] == generation { self.statuses[device.id] = previous }
            }
            catch {
                guard self.generations[device.id] == generation else { return }
                var failed = previous
                failed.busy = false; failed.error = error.localizedDescription
                self.statuses[device.id] = failed
                var schedule = self.schedules[device.id] ?? RemoteSyncSchedule()
                schedule.failed(at: Date())
                self.schedules[device.id] = schedule
            }
        }
    }

    func testDraft(_ device: RemoteDevice) async throws -> DeviceConnectionTestResult {
        guard let service else { throw DeviceConfigurationError.invalidConfiguration }
        return try await service.test(device)
    }

    func test(_ device: RemoteDevice) {
        guard !suspended, !collectionPaused, tasks[device.id] == nil, !editingIDs.contains(device.id), let service else { return }
        let previous = statuses[device.id] ?? Status()
        let generation = UUID()
        generations[device.id] = generation
        var status = previous
        status.busy = true; status.testing = true; status.progress = nil
        status.connectionTest = nil; status.connectionTestError = nil
        statuses[device.id] = status
        tasks[device.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[device.id] = nil; self.generations[device.id] = nil }
            do {
                let result = try await service.test(device)
                try Task.checkCancellation()
                guard self.generations[device.id] == generation else { return }
                var finished = previous
                finished.connectionTest = result
                finished.connectionTestError = nil
                self.statuses[device.id] = finished
            } catch is CancellationError {
                if self.generations[device.id] == generation { self.statuses[device.id] = previous }
            } catch {
                guard self.generations[device.id] == generation else { return }
                var failed = previous
                failed.connectionTest = nil
                failed.connectionTestError = error.localizedDescription
                self.statuses[device.id] = failed
            }
        }
    }

    func cancel(_ id: String) async {
        let task = tasks[id]
        task?.cancel()
        await task?.value
    }

    func refreshAll() {
        for device in configuration.devices where device.enabled {
            schedules[device.id, default: RemoteSyncSchedule()].requestRefresh(at: Date())
            metadataRefreshedAt[device.id] = nil
        }
        tick()
    }

    func save(_ device: RemoteDevice, adding: Bool) async throws {
        guard let service else { return }
        guard editingIDs.insert(device.id).inserted else { return }
        defer { editingIDs.remove(device.id); updateMonitoring() }
        let sourceChanged = configuration.devices.first { $0.id == device.id }?.connection != device.connection
        if adding || sourceChanged { try await service.validateDirectory(device) }
        await cancel(device.id)
        try Task.checkCancellation()
        configuration = try service.configurations.update { configuration in
            if adding { configuration.devices.append(device) }
            else {
                guard let index = configuration.devices.firstIndex(where: { $0.id == device.id }) else { throw DeviceConfigurationError.missingDevice }
                configuration.devices[index] = device
            }
        }
        schedules[device.id] = RemoteSyncSchedule()
        if adding || sourceChanged {
            metadataRefreshedAt[device.id] = nil
            statuses[device.id] = nil
        }
        editingIDs.remove(device.id)
        await refreshCollectionDates()
        if device.enabled { run(device) }
    }

    func remove(_ device: RemoteDevice, deleteUsage: Bool) async throws {
        guard let service else { return }
        guard editingIDs.insert(device.id).inserted else { return }
        defer { editingIDs.remove(device.id); updateMonitoring() }
        await cancel(device.id)
        let previousName = configuration.removedNames[device.id]
        let previousIndex = configuration.devices.firstIndex(where: { $0.id == device.id }) ?? 0
        var removedConfiguration = false
        do {
            // Save the reversible configuration change before deleting historical facts.
            configuration = try service.configurations.update { try $0.remove(id: device.id, keepHistory: !deleteUsage) }
            removedConfiguration = true
            try await Task.detached(priority: .utility) {
                try service.store.removeDeviceData(device: device.id, deleteUsage: deleteUsage)
            }.value
        } catch {
            let failure = error
            var restorationFailed = false
            if removedConfiguration {
                do {
                    configuration = try service.configurations.update { configuration in
                        if !configuration.devices.contains(where: { $0.id == device.id }) {
                            configuration.devices.insert(device, at: min(previousIndex, configuration.devices.count))
                            configuration.removedNames[device.id] = previousName
                        }
                    }
                } catch { restorationFailed = true }
            }
            if restorationFailed {
                throw NSError(domain: "TokenTick.DeviceRemoval", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Removal failed and some connection settings could not be restored. Check this device's settings and password."),
                    NSUnderlyingErrorKey: failure
                ])
            }
            throw failure
        }
        statuses[device.id] = nil; schedules[device.id] = nil
        metadataRefreshedAt[device.id] = nil
        await onChange?()
    }

    private func tick() {
        guard !suspended, !collectionPaused else { return }
        reload()
        let now = Date()
        let candidates = configuration.devices.filter { device in
            !editingIDs.contains(device.id)
        }
        for device in RemoteSyncSchedule.dueDevices(candidates, schedules: schedules, running: Set(tasks.keys), at: now) {
            run(device, refreshMetadata: now.timeIntervalSince(metadataRefreshedAt[device.id] ?? .distantPast) >= 3_600)
        }
    }
}
