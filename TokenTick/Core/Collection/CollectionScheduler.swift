import Foundation

/// File notifications and polling share capacity, while each source runs serially.
actor CollectionScheduler {
    static let shared = CollectionScheduler()
    private struct Waiting {
        let id: UUID
        let key: String
        let continuation: CheckedContinuation<Void, Error>
    }
    private var active: [UUID: String] = [:]
    private var waiting: [Waiting] = []

    func run(key: String, operation: @escaping @Sendable () async throws -> DeviceSyncResult) async throws -> DeviceSyncResult {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await acquire(id, key: key)
            defer { finished(id) }
            try Task.checkCancellation()
            return try await operation()
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func acquire(_ id: UUID, key: String) async throws {
        try Task.checkCancellation()
        if active.count < 2, !active.values.contains(key) { active[id] = key; return }
        try await withCheckedThrowingContinuation {
            waiting.append(Waiting(id: id, key: key, continuation: $0))
        }
    }

    private func cancelWaiting(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func finished(_ id: UUID) {
        active[id] = nil
        while active.count < 2, let index = waiting.firstIndex(where: { !active.values.contains($0.key) }) {
            let next = waiting.remove(at: index)
            active[next.id] = next.key
            next.continuation.resume()
        }
    }
}
