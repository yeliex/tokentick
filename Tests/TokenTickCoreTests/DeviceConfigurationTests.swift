import Foundation
import Testing
@testable import TokenTickCore

struct DeviceConfigurationTests {
    @Test func savesOriginalAddressAndPasswordWithoutChangingSourceIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceConfigurationStore(directory: root)
        let address = "ssh://alice:p%40ss%3Aword@host:2222/Codex%20Data"
        var device = RemoteDevice(name: "Fixture", connection: try ParsedDeviceConnection(address: address).connection)
        device.address = address
        try store.update { $0.devices.append(device) }
        let saved = try #require(store.load().devices.first)
        #expect(saved.address == address)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        let row = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(row["connection"] == nil)
        #expect(saved.connection == device.connection)
        #expect(try ParsedDeviceConnection(address: #require(saved.address)).password == "p@ss:word")
        let changed = "ssh://alice:changed@host:2222/Codex%20Data"
        device.edit(name: device.name, connection: try ParsedDeviceConnection(address: changed).connection, enabled: true)
        device.address = changed
        #expect(device.sourceRevision == 0)
        try store.update { $0.devices[0] = device }
        #expect(try store.load().devices[0].address == changed)
        try store.update { try $0.remove(id: device.id, keepHistory: true) }
        #expect(try store.load().devices.isEmpty)
    }

    @Test func detectsFolderAddressesWithoutInspectingContents() throws {
        #expect(try ParsedDeviceConnection(address: "/Volumes/Remote/Codex Data").connection ==
                .directory(path: "/Volumes/Remote/Codex Data", bookmark: nil))
        #expect(try ParsedDeviceConnection(address: "file:///Volumes/Remote/Codex%20Data").connection ==
                .directory(path: "/Volumes/Remote/Codex Data", bookmark: nil))
        #expect(try ParsedDeviceConnection(address: "~/Codex Data").connection ==
                .directory(path: ("~/Codex Data" as NSString).expandingTildeInPath, bookmark: nil))
        #expect(throws: DeviceConfigurationError.self) { try ParsedDeviceConnection(address: "file://remote/share") }
        #expect(throws: DeviceConfigurationError.self) { try ParsedDeviceConnection(address: "ftp://host/data") }
    }

    @Test func refreshingFolderPermissionDoesNotChangeSourceIdentity() throws {
        var device = RemoteDevice(name: "Folder", connection: .directory(path: "/synthetic", bookmark: Data([1])))
        device.edit(name: "Folder", connection: .directory(path: "/synthetic", bookmark: Data([2])), enabled: true)
        #expect(device.sourceRevision == 0)
        #expect(try JSONDecoder().decode(RemoteDevice.self, from: JSONEncoder().encode(device)) == device)
        device.edit(name: "Folder", connection: .directory(path: "/different", bookmark: Data([2])), enabled: true)
        #expect(device.sourceRevision == 1)
    }
    @Test func parsesAliasesAndSeparatesSecrets() throws {
        #expect(try ParsedDeviceConnection(address: "ssh://workstation").connection ==
                .ssh(host: "workstation", user: nil, port: nil, codexHome: nil))
        let input = try ParsedDeviceConnection(address: "ssh://alice:p%40ss%3Aword@host:2222/D:/Codex%20Data")
        #expect(input.password == "p@ss:word")
        #expect(input.connection == .ssh(host: "host", user: "alice", port: 2222, codexHome: "/D:/Codex Data"))
        let data = try JSONEncoder().encode(input.connection)
        #expect(!String(decoding: data, as: UTF8.self).contains("p@ss"))
        #expect(input.connection.displayAddress == "ssh://alice@host:2222/D:/Codex%20Data")
    }

    @Test func handlesIPv6() throws {
        let input = try ParsedDeviceConnection(address: "ssh://alice@[::1]:2222/Codex%20Data")
        #expect(input.connection == .ssh(host: "[::1]", user: "alice", port: 2222, codexHome: "/Codex Data"))
        #expect(try ParsedDeviceConnection(address: input.connection.displayAddress).connection == input.connection)
    }

    @Test(arguments: ["ssh://host:CODEX_HOME", "ssh://host:0", "ssh://host:99999", "ssh://-host",
                      "ftp://host", "ssh://host/%xx", "ssh://host/%00",
                      "ssh://host/path?password=secret", "https://host/path"])
    func rejectsInvalidAddresses(_ address: String) {
        #expect(throws: DeviceConfigurationError.self) { try ParsedDeviceConnection(address: address) }
    }

    @Test func editsPreserveIdentityAndInvalidateOnlySourceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceConfigurationStore(directory: root)
        let connection = DeviceConnection.directory(path: "/selected/exactly", bookmark: nil)
        let device = RemoteDevice(name: "Original", connection: connection)
        #expect(device.id != "local")
        try store.update { $0.devices.append(device) }
        try store.update { $0.devices[0].edit(name: "Renamed", connection: connection, enabled: false) }
        var loaded = try store.load()
        #expect(loaded.devices[0].id == device.id)
        #expect(loaded.devices[0].sourceRevision == 0)
        try store.update {
            $0.devices[0].edit(name: "Renamed", connection: .directory(path: "/another", bookmark: nil), enabled: true)
        }
        loaded = try store.load()
        #expect(loaded.devices[0].sourceRevision == 1)
        try store.update { try $0.remove(id: device.id, keepHistory: true) }
        loaded = try store.load()
        #expect(loaded.devices.isEmpty)
        #expect(loaded.name(for: device.id) == "Renamed")
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!text.contains("/another"))
        #expect(!text.contains("/selected"))
    }

    @Test func invalidUpdateDoesNotReplaceConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceConfigurationStore(directory: root)
        let device = RemoteDevice(name: "Device", connection: .directory(path: "/not-validated-as-codex", bookmark: nil))
        try store.update { $0.devices.append(device) }
        #expect(throws: DeviceConfigurationError.self) { try store.update { $0.devices.append(device) } }
        #expect(try store.load().devices == [device])
    }
}
