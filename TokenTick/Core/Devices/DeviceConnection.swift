import Foundation

/// Parsed endpoint fields used for transport and password-free display.
public enum DeviceConnection: Codable, Equatable, Sendable {
    case ssh(host: String, user: String?, port: Int?, codexHome: String?)
    case directory(path: String, bookmark: Data?)

    public var kind: String {
        switch self {
        case .ssh: "ssh"
        case .directory: "directory"
        }
    }

    public var displayAddress: String {
        switch self {
        case .directory(let path, _): return path
        case .ssh(let host, let user, let port, let home):
            return Self.address(scheme: "ssh", host: host, user: user, port: port, path: home ?? "")

        }
    }

    private static func address(scheme: String, host: String, user: String?, port: Int?, path: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.user = user
        components.port = port
        components.path = path
        return components.string ?? scheme + "://" + host
    }
}

/// Parse the saved address when transport or authentication needs its components.
public struct ParsedDeviceConnection: Sendable {
    public let connection: DeviceConnection
    public let password: String?

    public init(address: String) throws {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("/") || input.hasPrefix("~/") {
            guard !input.contains("\0") else { throw DeviceConfigurationError.invalidAddress }
            connection = .directory(path: (input as NSString).expandingTildeInPath, bookmark: nil)
            password = nil
            return
        }
        if let url = URL(string: input), url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/"), !url.path.contains("\0") else { throw DeviceConfigurationError.invalidAddress }
            connection = .directory(path: url.path, bookmark: nil)
            password = nil
            return
        }
        let bytes = Array(input.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count,
                  Self.isHex(bytes[index + 1]), Self.isHex(bytes[index + 2]) else {
                throw DeviceConfigurationError.invalidAddress
            }
        }
        guard let components = URLComponents(string: input),
              components.scheme?.lowercased() == "ssh",
              let host = components.host, !host.isEmpty, !host.hasPrefix("-"),
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              components.query == nil, components.fragment == nil,
              components.port == nil || (1...65535).contains(components.port!),
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DeviceConfigurationError.invalidAddress
        }
        let user = components.user.flatMap { $0.isEmpty ? nil : $0 }
        let path = components.path
        guard ![host, user ?? "", path].contains(where: {
            $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw DeviceConfigurationError.invalidAddress }
        password = components.password
        let home = path.isEmpty ? nil : path
        connection = .ssh(host: host, user: user, port: components.port, codexHome: home)

    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

public enum DeviceConfigurationError: Error, LocalizedError {
    case invalidAddress, missingDevice, invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "Enter a valid SSH address with a numeric port, or choose a folder.", bundle: .module)
        case .missingDevice: String(localized: "The device configuration no longer exists.", bundle: .module)
        case .invalidConfiguration: String(localized: "The device configuration is invalid. Existing settings were kept.", bundle: .module)
        }
    }
}
