import Foundation
import Testing
@testable import TokenTickCore

struct DeviceAccountIdentityTests {
    @Test func readsOnlySelectedCredentialsAndDiscardsAccountSwitch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("auth.json")
        let data = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-selected","id_token":"unused","refresh_token":"must-not-refresh"}}"#.utf8)
        try data.write(to: file)
        let email = try DeviceAccountIdentity.read(root: root) { token in
            #expect(token == "fixture-selected")
            return "display@example.invalid"
        }
        #expect(email == "display@example.invalid")
        #expect(try Data(contentsOf: file) == data)
        let changed = try DeviceAccountIdentity.read(root: root) { _ in
            try? Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-new-account"}}"#.utf8).write(to: file)
            return "old@example.invalid"
        }
        #expect(changed == nil)
    }

    @Test(arguments: [
        #"{"auth_mode":"apikey","OPENAI_API_KEY":"fixture-key","tokens":{"access_token":"fixture-token"}}"#,
        #"{"tokens":{"access_token":"bad\r\nheader"}}"#,
        #"{"tokens":{"access_token":""}}"#,
        #"{"auth_mode":"unsupported","tokens":{"access_token":"fixture-token"}}"#,
        #"{"tokens":null}"#
    ]) func unsupportedCredentialsNeverMakeARequest(json: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(json.utf8).write(to: root.appendingPathComponent("auth.json"))
        let email = try DeviceAccountIdentity.read(root: root) { _ in
            Issue.record("Unsupported credentials reached the identity endpoint")
            return "unexpected@example.invalid"
        }
        #expect(email == nil)
    }

    @Test func escapingCredentialLinkIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        try Data(#"{"tokens":{"access_token":"fixture-outside"}}"#.utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("auth.json"), withDestinationURL: outside)
        #expect(throws: DeviceSourceFailure.invalidPath) {
            try DeviceAccountIdentity.read(root: root) { _ in Issue.record("Escaping credentials were read"); return nil }
        }
    }

    @Test(arguments: ["success", "denied", "missing-subject", "oversized", "redirect"])
    func identityHTTPResultsAreBoundedAndFailuresStayUnknown(scenario: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityProtocol.self]
        let result = DeviceAccountIdentity.fetch("fixture-" + scenario, configuration: configuration)
        #expect(result == (scenario == "success" ? "display@example.invalid" : nil))
    }
}

private final class IdentityProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard request.url?.absoluteString == "https://auth.openai.com/api/accounts/oauth/userinfo" else {
            Issue.record("Identity request followed a redirect")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        #expect(request.httpMethod == "GET")
        let scenario = request.value(forHTTPHeaderField: "Authorization") ?? ""
        if scenario == "Bearer fixture-redirect" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "https://example.invalid/identity"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://example.invalid/identity")!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status = scenario == "Bearer fixture-denied" ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes: Data
        switch scenario {
        case "Bearer fixture-oversized": bytes = Data(repeating: 32, count: 65_537)
        case "Bearer fixture-missing-subject": bytes = Data(#"{"email":"display@example.invalid"}"#.utf8)
        default: bytes = Data(#"{"sub":"fixture-user","email":"display@example.invalid"}"#.utf8)
        }
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}
