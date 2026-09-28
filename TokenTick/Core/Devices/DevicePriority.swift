import Foundation

/// Source precedence is independent of connection latency and scan completion order.
public struct DevicePriority: Sendable {
    private let created: [String: Date]

    public init(devices: [RemoteDevice] = []) {
        created = Dictionary(devices.map { ($0.id, $0.createdAt) }, uniquingKeysWith: min)
    }

    func prefers(_ incoming: String, over current: String) -> Bool {
        guard incoming != current else { return false }
        if incoming == "local" { return true }
        if current == "local" { return false }
        // Removed devices retain their historical ownership until an actual local copy is discovered.
        guard let left = created[incoming], let right = created[current] else { return false }
        return left == right ? incoming < current : left < right
    }
}
