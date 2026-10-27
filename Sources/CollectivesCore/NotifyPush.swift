import Foundation

extension CollectivesClient {
    public func notifyPushEndpoint() async throws -> URL? {
        struct Capabilities: Decodable {
            struct Values: Decodable {
                struct Push: Decodable {
                    struct Endpoints: Decodable { let websocket: URL? }
                    let endpoints: Endpoints?
                }
                let notify_push: Push?
            }
            let capabilities: Values
        }
        let result = try await ocs(Capabilities.self, path: ["ocs", "v2.php", "cloud", "capabilities"])
        guard let endpoint = result.capabilities.notify_push?.endpoints?.websocket else { return nil }
        return try NotifyPushListener.validatedEndpoint(endpoint, server: account.serverURL)
    }

    public func createPushSession(collectiveID: Int) async throws -> String {
        struct Session: Decodable { let token: String }
        return try await ocs(Session.self, path: pushSessionPath(collectiveID), method: "POST").token
    }

    public func refreshPushSession(collectiveID: Int, token: String) async throws {
        let _: [String] = try await ocs([String].self, path: pushSessionPath(collectiveID), method: "PUT",
                                      body: JSONEncoder().encode(["token": token]))
    }

    public func closePushSession(collectiveID: Int, token: String) async throws {
        let _: [String] = try await ocs([String].self, path: pushSessionPath(collectiveID), method: "DELETE",
                                      body: JSONEncoder().encode(["token": token]))
    }

    private func pushSessionPath(_ collectiveID: Int) -> [String] {
        ["ocs", "v2.php", "apps", "collectives", "api", "v1.0", "collectives", String(collectiveID), "sessions"]
    }
}

protocol PushConnection: Sendable {
    func send(_ message: String) async throws
    func receive() async throws -> String
    func ping() async throws
    func close()
}

private final class PushRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct WebSocketPushConnection: PushConnection {
    let session: URLSession
    let task: URLSessionWebSocketTask

    init(endpoint: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: PushRedirectDelegate(), delegateQueue: nil)
        var request = URLRequest(url: endpoint)
        request.setValue("Collectives Apple/0.1", forHTTPHeaderField: "User-Agent")
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1_024 * 1_024
        task.resume()
    }

    func send(_ message: String) async throws { try await task.send(.string(message)) }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let value): return value
        case .data(let value):
            guard let text = String(data: value, encoding: .utf8) else { throw CollectivesError.invalidResponse }
            return text
        @unknown default: throw CollectivesError.invalidResponse
        }
    }
    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

public enum NotifyPushListener {
    // Push is commonly hosted at /push even when Nextcloud uses a subdirectory.
    public static func validatedEndpoint(_ endpoint: URL, server: URL) throws -> URL {
        let server = try ServerAddress.normalize(server)
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == (server.scheme == "https" ? "wss" : "ws"),
              parts.host?.lowercased() == server.host?.lowercased(),
              (parts.port ?? (parts.scheme == "wss" ? 443 : 80)) == (server.port ?? (server.scheme == "https" ? 443 : 80)),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw CollectivesError.unsafeURL }
        return endpoint
    }

    public static func listen(endpoint: URL, account: Account, credential: Credential,
                              onAuthenticated: @escaping @Sendable () async -> Void,
                              onChange: @escaping @Sendable () async -> Void) async throws {
        let endpoint = try validatedEndpoint(endpoint, server: account.serverURL)
        try await listen(connection: WebSocketPushConnection(endpoint: endpoint), credential: credential,
                         onAuthenticated: onAuthenticated, onChange: onChange)
    }

    static func listen(connection: any PushConnection, credential: Credential,
                       onAuthenticated: @escaping @Sendable () async -> Void,
                       onChange: @escaping @Sendable () async -> Void) async throws {
        try await withTaskCancellationHandler {
            defer { connection.close() }
            try Task.checkCancellation()
            try await connection.send(credential.loginName)
            try await connection.send(credential.appPassword)
            let response = try await withTimeout(connection: connection) { try await connection.receive() }
            guard response == "authenticated" else { throw CollectivesError.invalidResponse }
            try Task.checkCancellation()
            await onAuthenticated()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        try Task.checkCancellation()
                        if isContentChange(message) { await onChange() }
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(30))
                        try await withTimeout(connection: connection) { try await connection.ping() }
                    }
                }
                do { _ = try await group.next() }
                catch {
                    connection.close()
                    group.cancelAll()
                    throw error
                }
                connection.close()
                group.cancelAll()
            }
        } onCancel: {
            connection.close()
        }
    }

    private static func withTimeout<T: Sendable>(connection: any PushConnection,
                                                 operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                connection.close()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    static func isContentChange(_ message: String) -> Bool {
        guard let name = message.split(separator: " ", maxSplits: 1).first.map(String.init) else { return false }
        return ["notify_file", "notify_file_id", "collectives_pagelist"].contains(name)
    }
}

public actor NotifyPushSessions {
    private let client: CollectivesClient
    private var tokens: [Int: String] = [:]
    public init(client: CollectivesClient) { self.client = client }

    public func refresh(collectiveIDs: [Int]) async throws {
        let desired = Set(collectiveIDs)
        for (id, token) in tokens where !desired.contains(id) {
            try await client.closePushSession(collectiveID: id, token: token)
            tokens.removeValue(forKey: id)
        }
        for id in desired.sorted() {
            try Task.checkCancellation()
            if let token = tokens[id] {
                do {
                    try await client.refreshPushSession(collectiveID: id, token: token)
                } catch CollectivesError.http(404) {
                    tokens[id] = try await client.createPushSession(collectiveID: id)
                }
            } else {
                tokens[id] = try await client.createPushSession(collectiveID: id)
            }
        }
    }

    public func close() async {
        let previous = tokens
        tokens.removeAll()
        for (id, token) in previous { try? await client.closePushSession(collectiveID: id, token: token) }
    }
}
