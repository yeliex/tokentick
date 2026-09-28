import Foundation

public struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var connection: DeviceConnection
    public var address: String?
    public var enabled: Bool
    public let createdAt: Date
    public private(set) var sourceRevision: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, address, bookmark, enabled, createdAt, sourceRevision
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        let savedAddress = try values.decode(String.self, forKey: .address)
        address = savedAddress
        connection = try ParsedDeviceConnection(address: savedAddress).connection
        if case .directory(let path, _) = connection {
            connection = .directory(path: path, bookmark: try values.decodeIfPresent(Data.self, forKey: .bookmark))
        }
        enabled = try values.decode(Bool.self, forKey: .enabled)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        sourceRevision = try values.decode(Int.self, forKey: .sourceRevision)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(address ?? connection.displayAddress, forKey: .address)
        if case .directory(_, let bookmark) = connection {
            try values.encodeIfPresent(bookmark, forKey: .bookmark)
        }
        try values.encode(enabled, forKey: .enabled)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(sourceRevision, forKey: .sourceRevision)
    }

    public init(name: String, connection: DeviceConnection, enabled: Bool = true) {
        id = UUID().uuidString.lowercased()
        self.name = name
        self.connection = connection
        address = connection.displayAddress
        self.enabled = enabled
        createdAt = Date()
        sourceRevision = 0
    }

    static func local(root: URL) -> Self { Self(localRoot: root) }

    private init(localRoot: URL) {
        id = "local"
        name = "Local"
        connection = .directory(path: localRoot.path, bookmark: nil)
        address = localRoot.path
        enabled = true
        createdAt = .distantPast
        sourceRevision = 0
    }

    public mutating func edit(name: String, connection: DeviceConnection, enabled: Bool) {
        // A new source cannot inherit byte offsets from an old endpoint, even though its device ID is stable.
        let sourceChanged: Bool
        if case .directory(let previous, _) = self.connection, case .directory(let next, _) = connection {
            sourceChanged = previous != next
        } else { sourceChanged = self.connection != connection }
        if sourceChanged { sourceRevision += 1; address = connection.displayAddress }
        self.name = name
        self.connection = connection
        self.enabled = enabled
    }
}

public struct DeviceConfiguration: Codable, Equatable, Sendable {
    public var devices: [RemoteDevice] = []
    public var removedNames: [String: String] = [:]
    public var dismissedRemoteHintIDs: Set<String>?

    public init() {}

    public func name(for id: String) -> String? {
        devices.first { $0.id == id }?.name ?? removedNames[id]
    }

    public mutating func remove(id: String, keepHistory: Bool) throws {
        guard let device = devices.first(where: { $0.id == id }) else {
            throw DeviceConfigurationError.missingDevice
        }
        devices.removeAll { $0.id == id }
        if keepHistory { removedNames[id] = device.name }
        else { removedNames.removeValue(forKey: id) }
    }

    func validate() throws {
        let ids = devices.map(\.id)
        guard Set(ids).count == ids.count,
              ids.allSatisfy({ UUID(uuidString: $0) != nil }),
              devices.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.sourceRevision >= 0 }),
              removedNames.keys.allSatisfy({ UUID(uuidString: $0) != nil && !ids.contains($0) }) else {
            throw DeviceConfigurationError.invalidConfiguration
        }
        for device in devices {
            if let address = device.address, try ParsedDeviceConnection(address: address).connection.displayAddress != device.connection.displayAddress {
                throw DeviceConfigurationError.invalidConfiguration
            }
            switch device.connection {
            case .directory(let path, _):
                guard path.hasPrefix("/"), !path.contains("\0") else { throw DeviceConfigurationError.invalidConfiguration }
            default:
                guard try ParsedDeviceConnection(address: device.connection.displayAddress).connection == device.connection else {
                    throw DeviceConfigurationError.invalidConfiguration
                }
            }
        }
    }
}

/// Configuration survives usage database rebuilds; the lock serializes configuration writes.
public struct DeviceConfigurationStore: Sendable {
    public let url: URL

    public init(directory: URL = UsageStore.defaultDatabaseURL.deletingLastPathComponent()) {
        url = directory.appendingPathComponent("devices.json")
    }

    public func load() throws -> DeviceConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return DeviceConfiguration() }
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(DeviceConfiguration.self, from: data)
        try value.validate()
        return value
    }

    @discardableResult
    public func update(_ change: (inout DeviceConfiguration) throws -> Void) throws -> DeviceConfiguration {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try FileWriteLock(url: url.appendingPathExtension("lock")).withLock {
            var value = try load()
            try change(&value)
            try value.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return value
        }
    }
}
