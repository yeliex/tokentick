import Foundation

struct DeviceAccount: Codable, Sendable {
    let id: String?
    let email: String?

    static func read(session: CodexAPISession) throws -> Self {
        let limits: CodexRateLimits = try session.request("account/rateLimits/read")
        let profile: CodexAccountResponse? = try? session.request("account/read", params: ["refreshToken": false])
        try Task.checkCancellation()
        return Self(id: limits.accountId.flatMap { $0.isEmpty ? nil : $0 },
                    email: profile?.account?.email)
    }

    static func read(root: URL) throws -> Self {
        let session = try CodexAPISession(executable: CodexAPIClient.resolveExecutable(explicit: nil), codexHome: root)
        defer { session.close() }
        return try read(session: session)
    }
}
