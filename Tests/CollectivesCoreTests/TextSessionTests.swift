import Foundation
import Testing
@testable import CollectivesCore

private let textAccount = Account(serverURL: URL(string: "https://cloud.example.test/nextcloud")!, userID: "alice")
private let openedText = ##"{"document":{"id":"opaque-document","baseVersionEtag":"collaboration-base","lastSavedVersion":0},"session":{"id":17,"token":"native-session-secret"},"content":"# Original","readOnly":false}"##

private actor TextTransport: HTTPTransport {
    enum Response: Sendable {
        case json(String, status: Int = 200)
        case held(String, status: Int = 200)
        case failure
        case redirected
    }
    var requests: [URLRequest] = []
    var responses: [Response]
    private var gate: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var holding = false

    init(_ responses: [Response]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw TextSessionError.invalidResponse }
        let response = responses.removeFirst()
        let body: String
        let status: Int
        switch response {
        case .json(let value, let code): body = value; status = code
        case .held(let value, let code):
            body = value; status = code
            await withCheckedContinuation { continuation in
                gate = continuation; holding = true
                arrival?.resume(); arrival = nil
            }
        case .failure: throw URLError(.networkConnectionLost)
        case .redirected:
            return (Data("{}".utf8), HTTPURLResponse(url: URL(string: "https://other.example.test/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func waitUntilHeld() async {
        if holding { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { gate?.resume(); gate = nil; holding = false }
}

private func textClient(_ transport: TextTransport, limit: Int = 4 * 1_024 * 1_024) throws -> TextSessionClient {
    try TextSessionClient(client: CollectivesClient(account: textAccount,
        credential: Credential(loginName: "login-name", appPassword: "native-app-secret"), transport: transport),
        fileID: 42, maximumMessageBytes: limit)
}

@Test func textSessionAuthenticatesAndKeepsCredentialsOutOfReplies() async throws {
    let transport = TextTransport([.json(openedText), .json("{}")])
    let client = try textClient(transport)
    let opened = try await client.send(.open, leaseID: client.leaseID)
    let reply = String(decoding: try JSONEncoder().encode(opened), as: UTF8.self)
    #expect(!reply.contains("native-session-secret"))
    #expect(!reply.contains("native-app-secret"))
    #expect(reply.contains("native-owned"))
    _ = try await client.send(.sync(version: 0), leaseID: client.leaseID)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["PUT", "POST"])
    #expect(requests[0].url?.path == "/nextcloud/index.php/apps/text/session/file/42/create")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("login-name:native-app-secret".utf8).base64EncodedString())
    #expect(requests[0].value(forHTTPHeaderField: "OCS-APIRequest") == "true")
    #expect(requests[0].value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
    let body = try JSONDecoder().decode([String: TextValue].self, from: requests[1].httpBody!)
    #expect(body["sessionToken"] == .string("native-session-secret"))
    #expect(body["documentId"] == .string("opaque-document"))
    #expect(body["baseVersionEtag"] == .string("collaboration-base"))
}

@Test func textSessionRejectsForeignLeaseAndInvalidMessagesBeforeNetworking() async throws {
    let transport = TextTransport([])
    let client = try textClient(transport)
    await #expect(throws: TextSessionError.staleLease) { try await client.send(.open, leaseID: UUID()) }
    await #expect(throws: TextSessionError.invalidMessage) { try await client.send(.sync(version: -2), leaseID: client.leaseID) }
    await #expect(throws: TextSessionError.invalidMessage) {
        try await client.send(.push(version: 0, steps: ["not base64"], awareness: "", recoveryAttempt: nil), leaseID: client.leaseID)
    }
    #expect(await transport.requests.isEmpty)
}

@Test func textSessionDoesNotMistakeHTTP200ForConfirmedSave() async throws {
    let transport = TextTransport([.json(openedText), .json(#"{"document":{"lastSavedVersion":3}}"#), .json(#"{"document":{"lastSavedVersion":9}}"#)])
    let client = try textClient(transport)
    _ = try await client.send(.open, leaseID: client.leaseID)
    let pending = try await client.send(.save(version: 9, markdown: "edited", documentState: "AA==", manual: true), leaseID: client.leaseID)
    #expect(pending.saveConfirmed == false)
    let confirmed = try await client.send(.save(version: 9, markdown: "edited", documentState: "AA==", manual: true), leaseID: client.leaseID)
    #expect(confirmed.saveConfirmed == true)
    let requests = await transport.requests
    let body = try JSONDecoder().decode([String: TextValue].self, from: requests[1].httpBody!)
    #expect(body["force"] == .bool(false))
    #expect(body["manualSave"] == .bool(true))
}

@Test func textSessionBoundsBothDirectionsAndRejectsRedirects() async throws {
    let transport = TextTransport([.json(openedText)])
    let client = try textClient(transport, limit: 512)
    _ = try await client.send(.open, leaseID: client.leaseID)
    await #expect(throws: TextSessionError.messageTooLarge) {
        try await client.send(.save(version: 0, markdown: String(repeating: "a", count: 1024), documentState: "AA==", manual: true), leaseID: client.leaseID)
    }
    #expect(await transport.requests.count == 1)
    let oversized = try textClient(TextTransport([.json(String(repeating: "a", count: 1024))]), limit: 512)
    await #expect(throws: TextSessionError.messageTooLarge) { try await oversized.send(.open, leaseID: oversized.leaseID) }
    let redirected = try textClient(TextTransport([.redirected]))
    await #expect(throws: CollectivesError.self) { try await redirected.send(.open, leaseID: redirected.leaseID) }
}

@Test func textSessionFailedOpenCannotBeAutomaticallyReplayed() async throws {
    let transport = TextTransport([.failure])
    let client = try textClient(transport)
    await #expect(throws: URLError.self) { try await client.send(.open, leaseID: client.leaseID) }
    #expect(await client.phase == .recoveryRequired)
    await #expect(throws: TextSessionError.invalidState) { try await client.send(.open, leaseID: client.leaseID) }
    #expect(await transport.requests.count == 1)
}

@Test func textSessionRejectsMalformedAndUnsafeServerIdentity() async throws {
    for payload in ["{}", openedText.replacingOccurrences(of: "opaque-document", with: "../outside"),
                    openedText.replacingOccurrences(of: "\"token\":\"native-session-secret\"", with: "\"token\":\"\"")] {
        let client = try textClient(TextTransport([.json(payload)]))
        await #expect(throws: (any Error).self) { try await client.send(.open, leaseID: client.leaseID) }
        #expect(await client.phase == .recoveryRequired)
    }
}

@Test func textSessionCloseWaitsForPushAndSaveCannotRacePush() async throws {
    let transport = TextTransport([.json(openedText), .held("{}"), .json("[]")])
    let client = try textClient(transport)
    _ = try await client.send(.open, leaseID: client.leaseID)
    let push = Task { try await client.send(.push(version: 0, steps: ["AA=="], awareness: "", recoveryAttempt: nil), leaseID: client.leaseID) }
    await transport.waitUntilHeld()
    await #expect(throws: TextSessionError.invalidState) { try await client.send(.close, leaseID: client.leaseID) }
    await #expect(throws: TextSessionError.invalidState) {
        try await client.send(.save(version: 0, markdown: "edit", documentState: "AA==", manual: true), leaseID: client.leaseID)
    }
    await transport.release()
    _ = try await push.value
    _ = try await client.send(.close, leaseID: client.leaseID)
    #expect(await client.phase == .closed)
    await #expect(throws: TextSessionError.invalidState) { try await client.send(.sync(version: 0), leaseID: client.leaseID) }
}

@Test func textSessionInvalidationRejectsLateReplies() async throws {
    let transport = TextTransport([.json(openedText), .held("{}"), .json("{}", status: 403)])
    let client = try textClient(transport)
    _ = try await client.send(.open, leaseID: client.leaseID)
    let poll = Task { try await client.send(.sync(version: 0), leaseID: client.leaseID) }
    await transport.waitUntilHeld()
    await #expect(throws: TextSessionError.http(403)) {
        try await client.send(.push(version: 0, steps: ["AA=="], awareness: "", recoveryAttempt: nil), leaseID: client.leaseID)
    }
    await transport.release()
    await #expect(throws: TextSessionError.staleLease) { try await poll.value }
    #expect(await client.phase == .recoveryRequired)
}

@Test func textSessionCancellationBeforeOpenSendsNothing() async throws {
    let transport = TextTransport([])
    let client = try textClient(transport)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await client.send(.open, leaseID: client.leaseID)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await client.phase == .idle)
    #expect(await transport.requests.isEmpty)
}

@Test func textSessionCancelledOpenRetainsAmbiguousOwnership() async throws {
    let transport = TextTransport([.held(openedText)])
    let client = try textClient(transport)
    let task = Task { try await client.send(.open, leaseID: client.leaseID) }
    await transport.waitUntilHeld()
    await #expect(throws: TextSessionError.invalidState) { try await client.send(.open, leaseID: client.leaseID) }
    task.cancel()
    await transport.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await client.phase == .recoveryRequired)
    #expect(await transport.requests.count == 1)
}

@Test func textSessionFailedOrMalformedCloseRequiresRecovery() async throws {
    for response in [TextTransport.Response.failure, .json(#"{"error":"not closed"}"#)] {
        let transport = TextTransport([.json(openedText), response])
        let client = try textClient(transport)
        _ = try await client.send(.open, leaseID: client.leaseID)
        await #expect(throws: (any Error).self) { try await client.send(.close, leaseID: client.leaseID) }
        #expect(await client.phase == .recoveryRequired)
    }
}
