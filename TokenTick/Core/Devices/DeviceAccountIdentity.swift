import Foundation
import Synchronization

/// Reads only the selected source's file credentials and asks the issuer for display identity.
/// Neither credentials nor the returned email are evidence for historical usage attribution.
enum DeviceAccountIdentity {
    static func read(root: URL, lookup: (String) -> String? = { fetch($0) }) throws -> String? {
        let directory = root.resolvingSymlinksInPath().standardizedFileURL
        let file = directory.appendingPathComponent("auth.json").resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(directory.path == "/" ? "/" : directory.path + "/") else {
            throw DeviceSourceFailure.invalidPath
        }
        func contents() throws -> Data {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 1_048_577) ?? Data()
            guard bytes.count <= 1_048_576 else { throw DeviceSourceFailure.unsupported }
            return bytes
        }
        let before = try contents()
        guard let token = try accessToken(from: before) else { return nil }
        let email = lookup(token)
        // A sign-out or account switch during the request invalidates the display result.
        guard try contents() == before else { return nil }
        return email
    }

    static func accessToken(from bytes: Data) throws -> String? {
        guard bytes.count <= 1_048_576 else { throw DeviceSourceFailure.unsupported }
        let auth = try JSONDecoder().decode(Credentials.self, from: bytes)
        guard auth.authMode == nil || auth.authMode == "chatgpt",
              auth.apiKey == nil, let token = auth.tokens?.accessToken, !token.isEmpty,
              token.utf8.count <= 16_384, token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { return nil }
        return token
    }

    static func fetch(_ token: String, configuration: URLSessionConfiguration = .ephemeral) -> String? {
        // This endpoint is published by auth.openai.com's OpenID discovery document.
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/userinfo")!)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let receiver = IdentityResponse()
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        guard receiver.finished.wait(timeout: .now() + 20) == .success else { task.cancel(); return nil }
        return receiver.email
    }

    private struct Credentials: Decodable {
        let authMode: String?
        let apiKey: String?
        let tokens: Tokens?
        struct Tokens: Decodable {
            let accessToken: String?
            enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
        }
        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode", apiKey = "OPENAI_API_KEY", tokens
        }
    }
}

/// Used only in a disposable worker; bounded synchronous waiting cannot stall the app's UI or scanner.
private final class IdentityResponse: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var bytes = Data()
        var accepted = false
        var failed = false
    }
    private let state = Mutex(State())
    let finished = DispatchSemaphore(value: 0)

    var email: String? {
        state.withLock { value in
            guard value.accepted, !value.failed,
                  let identity = try? JSONDecoder().decode(Profile.self, from: value.bytes),
                  !identity.sub.isEmpty, let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty, email.utf8.count <= 1_024 else { return nil }
            return email
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward a source credential to a redirected origin, even if a server requests it.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let accepted = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= 65_536
        state.withLock { $0.accepted = accepted }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = state.withLock { value in
            guard value.bytes.count + data.count <= 65_536 else { value.failed = true; return true }
            value.bytes.append(data)
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock { $0.failed = $0.failed || error != nil }
        finished.signal()
    }

    private struct Profile: Decodable {
        let sub: String
        let email: String?
    }
}
