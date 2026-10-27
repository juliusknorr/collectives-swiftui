import Foundation
import Testing
@testable import CollectivesCore

private let pushAccount = Account(serverURL: URL(string: "https://cloud.example.test/nextcloud")!, userID: "alice")
private let pushCredential = Credential(loginName: "alice", appPassword: "app-password")

@Test func pushEndpointsRequireSecureSameOriginWithoutCredentialsOrParameters() throws {
    let endpoint = URL(string: "wss://cloud.example.test/push/ws")!
    #expect(try NotifyPushListener.validatedEndpoint(endpoint, server: pushAccount.serverURL) == endpoint)
    for value in ["ws://cloud.example.test/push/ws", "wss://evil.example/push/ws", "wss://cloud.example.test:444/push/ws",
                  "wss://alice:secret@cloud.example.test/push/ws", "wss://cloud.example.test/push/ws?token=secret",
                  "wss://cloud.example.test/push/ws#fragment", "https://cloud.example.test/push/ws"] {
        #expect(throws: CollectivesError.self) {
            try NotifyPushListener.validatedEndpoint(URL(string: value)!, server: pushAccount.serverURL)
        }
    }
    let local = URL(string: "http://localhost:8080/nextcloud")!
    #expect(try NotifyPushListener.validatedEndpoint(URL(string: "ws://localhost:8080/push/ws")!, server: local).scheme == "ws")
}

private actor PushHTTPTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let endpoint: String?
    init(endpoint: String? = "wss://cloud.example.test/push/ws") { self.endpoint = endpoint }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let payload: String
        if request.url!.path.hasSuffix("capabilities") {
            payload = endpoint.map { "{\"capabilities\":{\"notify_push\":{\"endpoints\":{\"websocket\":\"\($0)\"}}}}" }
                ?? "{\"capabilities\":{}}"
        } else if request.httpMethod == "POST" {
            payload = "{\"token\":\"session-token\"}"
        } else { payload = "[]" }
        let data = Data("{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":\(payload)}}".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func pushDiscoveryAuthenticatesAndHandlesUnsupportedServers() async throws {
    let transport = PushHTTPTransport()
    let client = CollectivesClient(account: pushAccount, credential: pushCredential, transport: transport)
    #expect(try await client.notifyPushEndpoint()?.absoluteString == "wss://cloud.example.test/push/ws")
    let requests = await transport.requests
    #expect(requests[0].url?.path == "/nextcloud/ocs/v2.php/cloud/capabilities")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("alice:app-password".utf8).base64EncodedString())
    let unsupported = CollectivesClient(account: pushAccount, credential: pushCredential, transport: PushHTTPTransport(endpoint: nil))
    #expect(try await unsupported.notifyPushEndpoint() == nil)
    let unsafe = CollectivesClient(account: pushAccount, credential: pushCredential, transport: PushHTTPTransport(endpoint: "wss://evil.example/ws"))
    await #expect(throws: CollectivesError.self) { try await unsafe.notifyPushEndpoint() }
}

@Test func pushSessionsRegisterHeartbeatAndCloseRemovedCollectives() async throws {
    let transport = PushHTTPTransport()
    let sessions = NotifyPushSessions(client: CollectivesClient(account: pushAccount, credential: pushCredential, transport: transport))
    try await sessions.refresh(collectiveIDs: [1, 2, 2])
    try await sessions.refresh(collectiveIDs: [2])
    await sessions.close()
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "POST", "DELETE", "PUT", "DELETE"])
    #expect(requests[0].url!.path.hasSuffix("/collectives/1/sessions"))
    #expect(requests[1].url!.path.hasSuffix("/collectives/2/sessions"))
    let body = try JSONDecoder().decode([String: String].self, from: requests[3].httpBody!)
    #expect(body == ["token": "session-token"])
}

private final class TestPushConnection: PushConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String]
    private var sentMessages: [String] = []
    private var wasClosed = false
    init(_ messages: [String]) { self.messages = messages }
    var sent: [String] { lock.withLock { sentMessages } }
    var closed: Bool { lock.withLock { wasClosed } }
    func send(_ message: String) async throws { lock.withLock { sentMessages.append(message) } }
    func receive() async throws -> String {
        try lock.withLock {
            guard !messages.isEmpty else { throw CancellationError() }
            return messages.removeFirst()
        }
    }
    func close() { lock.withLock { wasClosed = true } }
    func ping() async throws {}
}
private actor PushEvents {
    var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

@Test func pushAuthenticatesBeforeDeliveringRelevantEventsAndClosesOnDisconnect() async throws {
    let connection = TestPushConnection(["authenticated", "notify_notification", "notify_file", "collectives_pagelist {\"collectiveId\":1}", "notify_file_id [12]"])
    let events = PushEvents()
    await #expect(throws: CancellationError.self) {
        try await NotifyPushListener.listen(connection: connection, credential: pushCredential,
            onAuthenticated: { await events.record("authenticated") }, onChange: { await events.record("change") })
    }
    #expect(connection.sent == ["alice", "app-password"])
    #expect(connection.closed)
    #expect(await events.events == ["authenticated", "change", "change", "change"])
}

@Test func pushRejectsFailedAuthenticationWithoutDeliveringEvents() async {
    let connection = TestPushConnection(["err Invalid credentials", "notify_file"])
    let events = PushEvents()
    await #expect(throws: CollectivesError.self) {
        try await NotifyPushListener.listen(connection: connection, credential: pushCredential,
            onAuthenticated: { await events.record("authenticated") }, onChange: { await events.record("change") })
    }
    #expect(connection.closed)
    #expect(await events.events.isEmpty)
}

@Test func pushCancellationClosesBeforeSendingCredentials() async throws {
    let connection = TestPushConnection(["authenticated"])
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await NotifyPushListener.listen(connection: connection, credential: pushCredential,
                                            onAuthenticated: {}, onChange: {})
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(connection.sent.isEmpty)
    #expect(connection.closed)
}

@Test func pushChangeMessagesMatchCompleteEventNames() {
    for message in ["notify_file", "notify_file_id [1,2]", "collectives_pagelist {\"collectiveId\":1}"] {
        #expect(NotifyPushListener.isContentChange(message))
    }
    for message in ["", "authenticated", "notify_notification", "notify_file_other", "collectives_pagelist_other {}"] {
        #expect(!NotifyPushListener.isContentChange(message))
    }
}
