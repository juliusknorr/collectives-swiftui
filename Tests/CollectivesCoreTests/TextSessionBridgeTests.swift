import Foundation
import Testing
@testable import CollectivesCore

private actor BridgeTransport: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let json: String
        switch request.url!.lastPathComponent {
        case "create": json = #"{"document":{"id":"doc","baseVersionEtag":"base"},"session":{"id":7,"token":"native-secret"}}"#
        case "save": json = #"{"document":{"lastSavedVersion":3}}"#
        default: json = "{}"
        }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func bridgeClient(_ transport: BridgeTransport, maximumBytes: Int = 4096) throws -> TextSessionClient {
    try TextSessionClient(client: CollectivesClient(
        account: Account(serverURL: URL(string: "https://cloud.example.test")!, userID: "alice"),
        credential: Credential(loginName: "alice", appPassword: "example"), transport: transport),
        fileID: 42, maximumMessageBytes: maximumBytes)
}

private let bridgeIdentity: [String: TextValue] = [
    "documentId": .string("doc"), "sessionId": .integer(7), "sessionToken": .string("native-owned"),
    "baseVersionEtag": .string("base"),
]

private func bridgeBody(_ extra: [String: TextValue] = [:]) throws -> Data {
    try JSONEncoder().encode(bridgeIdentity.merging(extra) { _, new in new })
}

@Test func sharedBridgeDecodesAllOperationsAndKeepsRealTokenNative() async throws {
    let transport = BridgeTransport()
    let client = try bridgeClient(transport)
    let open = try await client.sendBridgeRequest(operation: "create", body: Data("{}".utf8), leaseID: client.leaseID)
    #expect(open.payload.object?["session"]?.object?["token"] == .string("native-owned"))
    _ = try await client.sendBridgeRequest(operation: "sync", body: bridgeBody(["version": .integer(-1)]), leaseID: client.leaseID)
    _ = try await client.sendBridgeRequest(operation: "push", body: bridgeBody([
        "version": .integer(0), "steps": .array([.string("AA==")]), "awareness": .string(""), "recoveryAttempt": .integer(1),
    ]), leaseID: client.leaseID)
    let save = try await client.sendBridgeRequest(operation: "save", body: bridgeBody([
        "version": .integer(3), "autosaveContent": .string("こんにちは"), "documentState": .string("AA=="),
        "force": .bool(false), "manualSave": .bool(true), "filePath": .string("ignored"), "token": .null,
    ]), leaseID: client.leaseID)
    #expect(save.saveConfirmed == true)
    _ = try await client.sendBridgeRequest(operation: "close", body: bridgeBody(), leaseID: client.leaseID)
    let requests = await transport.requests
    #expect(requests.count == 5)
    for request in requests.dropFirst() {
        let body = try JSONDecoder().decode([String: TextValue].self, from: request.httpBody!)
        #expect(body["sessionToken"] == .string("native-secret"))
        #expect(body["filePath"] == nil)
    }
}

@Test func sharedBridgeRejectsForeignIdentityAndStaleBaseWithoutNetworking() async throws {
    let transport = BridgeTransport()
    let client = try bridgeClient(transport)
    _ = try await client.sendBridgeRequest(operation: "create", body: Data("{}".utf8), leaseID: client.leaseID)
    for extra: [String: TextValue] in [
        ["documentId": .string("other")], ["sessionId": .integer(8)], ["sessionId": .bool(true)],
        ["sessionToken": .string("native-secret")], ["baseVersionEtag": .string("other-base")],
    ] {
        await #expect(throws: TextSessionError.staleLease) {
            try await client.sendBridgeRequest(operation: "sync", body: bridgeBody(extra.merging(["version": .integer(0)]) { _, new in new }), leaseID: client.leaseID)
        }
    }
    await #expect(throws: TextSessionError.staleLease) {
        try await client.sendBridgeRequest(operation: "close", body: bridgeBody(), leaseID: UUID())
    }
    #expect(await transport.requests.count == 1)
}

@Test func sharedBridgeRejectsRequestOverridesAndMalformedFieldsWithoutNetworking() async throws {
    let transport = BridgeTransport()
    let client = try bridgeClient(transport)
    _ = try await client.sendBridgeRequest(operation: "create", body: Data("{}".utf8), leaseID: client.leaseID)
    let validSave: [String: TextValue] = ["version": .integer(0), "autosaveContent": .string("Work"),
        "documentState": .string("AA=="), "manualSave": .bool(true)]
    for extra: [String: TextValue] in [
        ["url": .string("https://other.test")], ["Authorization": .string("other")], ["fileID": .integer(50)],
        ["runtimeDigest": .string("other")], ["force": .bool(true)], ["manualSave": .integer(1)],
        ["token": .string("share-token")], ["version": .bool(true)], ["documentState": .string("invalid base64")],
    ] {
        await #expect(throws: TextSessionError.invalidMessage) {
            try await client.sendBridgeRequest(operation: "save", body: bridgeBody(validSave.merging(extra) { _, new in new }), leaseID: client.leaseID)
        }
    }
    for malformed in ["[]", "null", "true", "{", #"{"version":0.5}"#] {
        await #expect(throws: TextSessionError.invalidMessage) {
            try await client.sendBridgeRequest(operation: "sync", body: Data(malformed.utf8), leaseID: client.leaseID)
        }
    }
    await #expect(throws: TextSessionError.invalidMessage) {
        try await client.sendBridgeRequest(operation: "delete", body: bridgeBody(), leaseID: client.leaseID)
    }
    #expect(await transport.requests.count == 1)
}

@Test func sharedBridgeRejectsOversizedBodiesAndUnimplementedRecoveryOpen() async throws {
    let transport = BridgeTransport()
    let client = try bridgeClient(transport, maximumBytes: 512)
    await #expect(throws: TextSessionError.messageTooLarge) {
        try await client.sendBridgeRequest(operation: "create", body: Data(repeating: 32, count: 513), leaseID: client.leaseID)
    }
    for input: [String: TextValue] in [["baseVersionEtag": .string("cached-base")], ["fileID": .integer(99)]] {
        await #expect(throws: TextSessionError.invalidMessage) {
            try await client.sendBridgeRequest(operation: "create", body: JSONEncoder().encode(input), leaseID: client.leaseID)
        }
    }
    #expect(await transport.requests.isEmpty)
}
