import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private let loginServer = URL(string: "https://cloud.example.test")!
private let loginFlowJSON = #"{"login":"https://cloud.example.test/login/approve","poll":{"token":"same+token","endpoint":"https://cloud.example.test/login/poll"}}"#
private let loginCredentialsJSON = #"{"server":"https://cloud.example.test","loginName":"alice","appPassword":"test-password"}"#

private actor LoginRecoveryTransport: HTTPTransport {
    enum Reply: Sendable {
        case http(Int, String)
        case network(URLError.Code)
        case cancelTask
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw CollectivesError.http(400) }
        switch replies.removeFirst() {
        case .http(let status, let body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!)
        case .network(let code): throw URLError(code)
        case .cancelTask:
            withUnsafeCurrentTask { $0?.cancel() }
            throw URLError(.cancelled)
        }
    }
}

private actor LoginDelayCounter {
    private(set) var count = 0
    func wait() { count += 1 }
}

private actor LoginDelayGate {
    private var entered = false
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        observer?.resume(); observer = nil
        if !released { await withCheckedContinuation { pending = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observer = $0 } }
    }
    func release() {
        released = true
        pending?.resume(); pending = nil
    }
}

@MainActor
private final class LoginRecoveryResults {
    var browserURLs: [URL] = []
    var finishes = 0
    var credentials: LoginCredentials?
    func open(_ url: URL) { browserURLs.append(url) }
    func finish(_ credentials: LoginCredentials) {
        finishes += 1
        self.credentials = credentials
    }
}

@MainActor
@Test(arguments: [URLError.Code.networkConnectionLost, .cancelled, .timedOut])
func loginPollRecoversConnectionLossWithoutCreatingAnotherBrowserFlow(code: URLError.Code) async throws {
    let transport = LoginRecoveryTransport([
        .http(200, loginFlowJSON), .network(code), .http(200, loginCredentialsJSON)
    ])
    let waits = LoginDelayCounter()
    let session = LoginSession(client: LoginFlowClient(transport: transport), delay: { await waits.wait() })
    let results = LoginRecoveryResults()
    await session.signIn(serverURL: loginServer, openBrowser: { results.open($0) }, finish: { results.finish($0) })
    #expect(!session.working)
    #expect(results.browserURLs.count == 1)
    #expect(results.finishes == 1)
    #expect(results.credentials?.appPassword == "test-password")
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests.map { $0.url?.path } == ["/index.php/login/v2", "/login/poll", "/login/poll"])
    #expect(requests[1].httpBody == requests[2].httpBody)
    #expect(await waits.count >= 1)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func loginDoesNotIssueRequestsWhileInactiveAndResumesOnReturn() async throws {
    let transport = LoginRecoveryTransport([.http(200, loginFlowJSON), .http(200, loginCredentialsJSON)])
    let gate = LoginDelayGate()
    let session = LoginSession(client: LoginFlowClient(transport: transport), delay: { await gate.wait() })
    session.isActive = false
    let results = LoginRecoveryResults()
    let task = Task { @MainActor in
        await session.signIn(serverURL: loginServer, openBrowser: { results.open($0) }, finish: { results.finish($0) })
    }
    await gate.waitUntilEntered()
    #expect(await transport.requests.isEmpty)
    #expect(results.browserURLs.isEmpty)
    session.isActive = true
    await gate.release()
    await task.value
    #expect(results.finishes == 1)
    #expect(await transport.requests.count == 2)
    #expect(!session.working)
}

@MainActor
@Test func loginRetriesAccountFinalizationWithoutPollingConsumedTokenAgain() async throws {
    let transport = LoginRecoveryTransport([.http(200, loginFlowJSON), .http(200, loginCredentialsJSON)])
    let waits = LoginDelayCounter()
    let session = LoginSession(client: LoginFlowClient(transport: transport), delay: { await waits.wait() })
    let results = LoginRecoveryResults()
    var attempts = 0
    await session.signIn(serverURL: loginServer, openBrowser: { results.open($0) }, finish: { credentials in
        attempts += 1
        if attempts == 1 { throw URLError(.networkConnectionLost) }
        results.finish(credentials)
    })
    #expect(attempts == 2)
    #expect(results.finishes == 1)
    #expect(results.browserURLs.count == 1)
    #expect(await transport.requests.count == 2)
    #expect(await waits.count >= 1)
}

@MainActor
@Test func loginRetainsReceivedCredentialsForManualFinalizationRetry() async throws {
    let transport = LoginRecoveryTransport([.http(200, loginFlowJSON), .http(200, loginCredentialsJSON)])
    let session = LoginSession(client: LoginFlowClient(transport: transport), delay: {})
    let results = LoginRecoveryResults()
    await session.signIn(serverURL: loginServer, openBrowser: { results.open($0) }, finish: { _ in
        throw CollectivesError.credential(-1)
    })
    #expect(!session.working)
    #expect(results.finishes == 0)
    await session.signIn(serverURL: loginServer, openBrowser: { results.open($0) }, finish: { results.finish($0) })
    #expect(results.finishes == 1)
    #expect(results.credentials?.loginName == "alice")
    #expect(results.credentials?.appPassword == "test-password")
    #expect(results.browserURLs.count == 1)
    #expect(await transport.requests.count == 2)
}

@MainActor
@Test func loginTaskCancellationDoesNotRetryCancelledURLRequest() async throws {
    let transport = LoginRecoveryTransport([.http(200, loginFlowJSON), .cancelTask])
    let waits = LoginDelayCounter()
    let session = LoginSession(client: LoginFlowClient(transport: transport), delay: { await waits.wait() })
    let results = LoginRecoveryResults()
    let task = Task { @MainActor in
        await session.signIn(serverURL: loginServer, openBrowser: { results.open($0) }, finish: { results.finish($0) })
    }
    await task.value
    #expect(results.finishes == 0)
    #expect(await transport.requests.count == 2)
    #expect(await waits.count <= 1)
    #expect(!session.working)
}

enum NonrecoverableLoginFailure: Sendable, CaseIterable {
    case certificate, unsafeOrigin, authentication
}

@MainActor
@Test(arguments: NonrecoverableLoginFailure.allCases)
func loginDoesNotRetryCertificateOriginOrAuthenticationFailures(failure: NonrecoverableLoginFailure) async throws {
    let replies: [LoginRecoveryTransport.Reply]
    let expectedRequests: Int
    switch failure {
    case .certificate:
        replies = [.http(200, loginFlowJSON), .network(.serverCertificateUntrusted)]
        expectedRequests = 2
    case .unsafeOrigin:
        replies = [.http(200, #"{"login":"https://other.example.test/login","poll":{"token":"token","endpoint":"https://other.example.test/poll"}}"#)]
        expectedRequests = 1
    case .authentication:
        replies = [.http(200, loginFlowJSON), .http(401, "")]
        expectedRequests = 2
    }
    let transport = LoginRecoveryTransport(replies)
    let waits = LoginDelayCounter()
    let session = LoginSession(client: LoginFlowClient(transport: transport), delay: { await waits.wait() })
    let results = LoginRecoveryResults()
    await session.signIn(serverURL: loginServer, openBrowser: { results.open($0) }, finish: { results.finish($0) })
    #expect(!session.working)
    #expect(results.finishes == 0)
    #expect(await transport.requests.count == expectedRequests)
    #expect(await waits.count <= 1)
}

private final class LoginRecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
    private var delays = 0
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }
    func delay() {
        lock.lock(); defer { lock.unlock() }
        delays += 1
        if delays > 1 { date = date.addingTimeInterval(20 * 60 + 1) }
    }
}

@MainActor
@Test func loginPollingExpiresInsteadOfRetryingIndefinitely() async throws {
    let transport = LoginRecoveryTransport([.http(200, loginFlowJSON), .http(404, "")])
    let clock = LoginRecoveryClock()
    let session = LoginSession(client: LoginFlowClient(transport: transport),
        delay: { clock.delay() }, now: { clock.now() })
    let results = LoginRecoveryResults()
    await session.signIn(serverURL: loginServer, openBrowser: { results.open($0) }, finish: { results.finish($0) })
    #expect(!session.working)
    #expect(results.finishes == 0)
    #expect(results.browserURLs.count == 1)
    #expect(await transport.requests.count == 2)
    #expect(session.status.lowercased().contains("expired"))
}

@MainActor
@Test(.timeLimit(.minutes(1))) func loginWaitsForReturnFromBrowserBeforePolling() async throws {
    let transport = LoginRecoveryTransport([.http(200, loginFlowJSON), .http(200, loginCredentialsJSON)])
    let gate = LoginDelayGate()
    let session = LoginSession(client: LoginFlowClient(transport: transport), delay: { await gate.wait() })
    let results = LoginRecoveryResults()
    let task = Task { @MainActor in
        await session.signIn(serverURL: loginServer, openBrowser: { url in
            results.open(url)
            session.isActive = false
        }, finish: { results.finish($0) })
    }
    await gate.waitUntilEntered()
    #expect(session.working)
    #expect(results.browserURLs.count == 1)
    #expect(results.finishes == 0)
    #expect(await transport.requests.count == 1)
    session.isActive = true
    await gate.release()
    await task.value
    #expect(results.finishes == 1)
    #expect(await transport.requests.count == 2)
    #expect(!session.working)
}

@MainActor
@Test func invalidLoginURLDoesNotIssueRequestsOrOpenBrowser() async throws {
    let transport = LoginRecoveryTransport([])
    let session = LoginSession(client: LoginFlowClient(transport: transport), delay: {})
    let results = LoginRecoveryResults()
    await session.signIn(serverURL: nil, openBrowser: { results.open($0) }, finish: { results.finish($0) })
    #expect(!session.working)
    #expect(results.browserURLs.isEmpty)
    #expect(results.finishes == 0)
    #expect(await transport.requests.isEmpty)
    #expect(session.status == CollectivesError.invalidServer.localizedDescription)
}
