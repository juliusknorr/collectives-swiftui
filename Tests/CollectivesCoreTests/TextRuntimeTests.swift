import Foundation
import Testing
@testable import CollectivesCore

private let runtimeManifest = TextRuntimeManifest(format: 1, textVersion: "10.0.0-dev.3",
    sourceRevision: String(repeating: "a", count: 40), codeDigest: String(repeating: "b", count: 64),
    sessionAPI: "context-v1", updateEncoding: "yjs-sync-v1")

private actor RuntimeTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let data: Data
    let status: Int
    var sessionStatus = 200
    init(manifest: TextRuntimeManifest = runtimeManifest, status: Int = 200) throws {
        data = try JSONEncoder().encode(manifest); self.status = status
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "GET" ? status : sessionStatus, httpVersion: nil, headerFields: nil)!
        if request.httpMethod == "PUT" {
            return (Data(#"{"document":{"id":"doc","baseVersionEtag":"base"},"session":{"id":1,"token":"secret"}}"#.utf8), response)
        }
        if request.httpMethod == "POST" {
            let body = request.url!.lastPathComponent == "save" ? #"{"document":{"lastSavedVersion":1}}"# : "{}"
            return (Data(body.utf8), response)
        }
        return (data, response)
    }
    func upgradeServer() { sessionStatus = 412 }
    func allowCleanup() { sessionStatus = 200 }
}

@Test func runtimeVerificationBindsAccountAndAddsDigestToNativeOpen() async throws {
    let transport = try RuntimeTransport()
    let account = Account(serverURL: URL(string: "https://cloud.example.test/subdir")!, userID: "alice")
    let credentials = Credential(loginName: "alice", appPassword: "native-only")
    let client = CollectivesClient(account: account, credential: credentials, transport: transport)
    let proof = try await client.verifyTextRuntime(expected: runtimeManifest)
    let session = try client.textSession(fileID: 41, verifiedRuntime: proof)
    _ = try await session.send(.open, leaseID: session.leaseID)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/subdir/index.php/apps/text/embedding")
    #expect(requests[0].value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") != nil)
    let body = try JSONDecoder().decode([String: TextValue].self, from: requests[1].httpBody!)
    #expect(body["runtimeDigest"] == .string(runtimeManifest.codeDigest))
    let otherAccount = Account(serverURL: account.serverURL, userID: "alice")
    let other = CollectivesClient(account: otherAccount, credential: credentials, transport: transport)
    #expect(throws: TextRuntimeError.differentAccount) { try other.textSession(fileID: 41, verifiedRuntime: proof) }
    #expect(await transport.requests.count == 2)

    for command in [TextSessionCommand.sync(version: 0), .push(version: 0, steps: ["AA=="], awareness: "", recoveryAttempt: nil),
                    .save(version: 1, markdown: "Example", documentState: "AA==", manual: true), .close] {
        _ = try await session.send(command, leaseID: session.leaseID)
        let request = try #require(await transport.requests.last)
        let body = try JSONDecoder().decode([String: TextValue].self, from: request.httpBody!)
        #expect(body["runtimeDigest"] == (command == .close ? nil : .string(runtimeManifest.codeDigest)))
    }
}

@Test func runtimeUpgradeDuringSessionRetainsRecoveryAndAllowsCleanup() async throws {
    let transport = try RuntimeTransport()
    let client = CollectivesClient(account: Account(serverURL: URL(string: "https://cloud.example.test")!, userID: "alice"),
                                  credential: Credential(loginName: "alice", appPassword: "example"), transport: transport)
    let proof = try await client.verifyTextRuntime(expected: runtimeManifest)
    let session = try client.textSession(fileID: 41, verifiedRuntime: proof)
    _ = try await session.send(.open, leaseID: session.leaseID)
    await transport.upgradeServer()
    await #expect(throws: TextSessionError.http(412)) { try await session.send(.sync(version: 0), leaseID: session.leaseID) }
    #expect(await session.phase == .recoveryRequired)
    await #expect(throws: TextSessionError.invalidState) {
        try await session.send(.save(version: 1, markdown: "Work", documentState: "AA==", manual: true), leaseID: session.leaseID)
    }
    await transport.allowCleanup()
    _ = try await session.send(.close, leaseID: session.leaseID)
    #expect(await session.phase == .closed)
}

@Test(arguments: [404, 503])
func runtimeVerificationFailsClosedWhenServerHasNoEmbeddingContract(status: Int) async throws {
    let transport = try RuntimeTransport(status: status)
    let client = CollectivesClient(account: Account(serverURL: URL(string: "http://localhost:18081")!, userID: "alice"),
                                  credential: Credential(loginName: "alice", appPassword: "example"), transport: transport)
    await #expect(throws: TextRuntimeError.unavailable) { try await client.verifyTextRuntime(expected: runtimeManifest) }
    #expect(await transport.requests.count == 1)
}

@Test func runtimeVerificationRejectsChangedBuildAndUnsupportedProtocol() async throws {
    let changed = TextRuntimeManifest(format: 1, textVersion: runtimeManifest.textVersion,
        sourceRevision: runtimeManifest.sourceRevision, codeDigest: String(repeating: "c", count: 64),
        sessionAPI: "context-v1", updateEncoding: "yjs-sync-v1")
    let transport = try RuntimeTransport(manifest: changed)
    let client = CollectivesClient(account: Account(serverURL: URL(string: "https://cloud.example.test")!, userID: "alice"),
                                  credential: Credential(loginName: "alice", appPassword: "example"), transport: transport)
    await #expect(throws: TextRuntimeError.incompatible) { try await client.verifyTextRuntime(expected: runtimeManifest) }
    let unsupported = TextRuntimeManifest(format: 2, textVersion: runtimeManifest.textVersion,
        sourceRevision: runtimeManifest.sourceRevision, codeDigest: runtimeManifest.codeDigest,
        sessionAPI: "context-v2", updateEncoding: "yjs-sync-v2")
    #expect(throws: TextRuntimeError.invalidManifest) { try unsupported.validate() }
    let invalid = TextRuntimeManifest(format: 1, textVersion: runtimeManifest.textVersion,
        sourceRevision: "../unexpected", codeDigest: runtimeManifest.codeDigest,
        sessionAPI: "context-v1", updateEncoding: "yjs-sync-v1")
    #expect(throws: TextRuntimeError.invalidManifest) { try invalid.validate() }
}
