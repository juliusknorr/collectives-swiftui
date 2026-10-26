import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
/// Redirects are rejected, including same-host redirects, to avoid credential forwarding.
private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CollectivesError.invalidResponse }
        return (data, response)
    }
}
public enum ServerAddress {
    public static func normalize(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else { throw CollectivesError.invalidServer }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = parts.path.isEmpty ? "" : "/" + parts.path
        guard let value = parts.url else { throw CollectivesError.invalidServer }
        return value
    }
    public static func isTrusted(_ url: URL, server: URL) -> Bool {
        guard url.scheme == server.scheme, url.host?.lowercased() == server.host?.lowercased(),
              effectivePort(url) == effectivePort(server), url.user == nil, url.password == nil,
              url.fragment == nil else { return false }
        let base = server.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = url.standardized.path
        return base.isEmpty || path == "/" + base || path.hasPrefix("/" + base + "/")
    }
    private static func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
    static func append(_ components: [String], to url: URL) throws -> URL {
        var result = url
        for component in components {
            guard component != ".", component != "..", !component.contains("/"), !component.contains("\\"),
                  !component.isEmpty else { throw CollectivesError.unsafeURL }
            result.appendPathComponent(component)
        }
        guard isTrusted(result, server: url) else { throw CollectivesError.unsafeURL }
        return result
    }
}
public struct LoginFlow: Decodable, Sendable {
    public struct Poll: Decodable, Sendable { public let token: String; public let endpoint: URL }
    public let login: URL
    public let poll: Poll
}
public struct LoginCredentials: Decodable, Sendable {
    public let server: URL
    public let loginName: String
    public let appPassword: String
}
public struct LoginFlowClient: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }
    public func begin(serverURL: URL) async throws -> LoginFlow {
        let server = try ServerAddress.normalize(serverURL)
        let url = try ServerAddress.append(["index.php", "login", "v2"], to: server)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Collectives Apple/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw CollectivesError.http(response.statusCode) }
        let flow = try JSONDecoder().decode(LoginFlow.self, from: data)
        guard ServerAddress.isTrusted(flow.poll.endpoint, server: server), ServerAddress.isTrusted(flow.login, server: server)
        else { throw CollectivesError.unsafeURL }
        return flow
    }
    public func poll(_ flow: LoginFlow, serverURL: URL) async throws -> LoginCredentials? {
        let server = try ServerAddress.normalize(serverURL)
        guard ServerAddress.isTrusted(flow.poll.endpoint, server: server) else { throw CollectivesError.unsafeURL }
        var request = URLRequest(url: flow.poll.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(("token=" + (flow.poll.token.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).utf8)
        let (data, response) = try await transport.send(request)
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw CollectivesError.http(response.statusCode) }
        let credentials = try JSONDecoder().decode(LoginCredentials.self, from: data)
        let returnedServer = try ServerAddress.normalize(credentials.server)
        guard ServerAddress.isTrusted(returnedServer, server: server),
              ServerAddress.isTrusted(server, server: returnedServer) else { throw CollectivesError.unsafeURL }
        return credentials
    }
}
private struct OCSEnvelope<T: Decodable>: Decodable {
    struct OCS: Decodable {
        struct Meta: Decodable { let statuscode: Int }
        let meta: Meta
        let data: T
    }
    let ocs: OCS
}
public struct CollectivesClient: Sendable {
    public let account: Account
    private let credential: Credential
    private let transport: any HTTPTransport
    public init(account: Account, credential: Credential, transport: any HTTPTransport = URLSessionTransport()) {
        self.account = account; self.credential = credential; self.transport = transport
    }
    private func request(_ components: [String]) throws -> URLRequest {
        let server = try ServerAddress.normalize(account.serverURL)
        var request = URLRequest(url: try ServerAddress.append(components, to: server))
        request.setValue("Basic " + Data((credential.loginName + ":" + credential.appPassword).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Collectives Apple/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }
    private func ocs<T: Decodable>(_ type: T.Type, path: [String], method: String = "GET", body: Data? = nil) async throws -> T {
        var outgoing = try request(path)
        outgoing.httpMethod = method
        outgoing.httpBody = body
        if body != nil { outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport.send(outgoing)
        guard response.statusCode == 200 else { throw CollectivesError.http(response.statusCode) }
        let envelope = try JSONDecoder().decode(OCSEnvelope<T>.self, from: data)
        guard [100, 200].contains(envelope.ocs.meta.statuscode) else { throw CollectivesError.http(envelope.ocs.meta.statuscode) }
        return envelope.ocs.data
    }
    public func currentUserID() async throws -> String {
        struct User: Decodable { let id: String }
        return try await ocs(User.self, path: ["ocs", "v2.php", "cloud", "user"]).id
    }
    public func collectives() async throws -> [Collective] {
        struct Result: Decodable { let collectives: [Collective] }
        return try await ocs(Result.self, path: ["ocs", "v2.php", "apps", "collectives", "api", "v1.0", "collectives"]).collectives
    }
    public func pages(collectiveID: Int) async throws -> [Page] {
        struct Result: Decodable { let pages: [Page] }
        return try await ocs(Result.self, path: ["ocs", "v2.php", "apps", "collectives", "api", "v1.0", "collectives", String(collectiveID), "pages"]).pages
    }
    public func createPage(collectiveID: Int, parentID: Int, title: String) async throws -> Page {
        struct Result: Decodable { let page: Page }
        let title = try PageCreator.title(title)
        return try await ocs(Result.self,
            path: ["ocs", "v2.php", "apps", "collectives", "api", "v1.0", "collectives", String(collectiveID), "pages", String(parentID)],
            method: "POST", body: JSONEncoder().encode(["title": title])).page
    }
    public func setPageEmoji(pageID: Int, collectiveID: Int, emoji: String?) async throws -> Page {
        struct Result: Decodable { let page: Page }
        let value: [String: String?] = ["emoji": emoji]
        return try await ocs(Result.self, path: ["ocs", "v2.php", "apps", "collectives", "api", "v1.0", "collectives", String(collectiveID), "pages", String(pageID), "emoji"], method: "PUT", body: JSONEncoder().encode(value)).page
    }
    public func documentURL(page: Page) throws -> URL {
        guard let collectivePath = page.collectivePath, !collectivePath.isEmpty else { throw CollectivesError.invalidResponse }
        let dirs = (collectivePath + "/" + page.filePath).split(separator: "/").map(String.init)
        return try request(["remote.php", "dav", "files", account.userID] + dirs + [page.fileName]).url!
    }
    private func documentRequest(page: Page) throws -> URLRequest {
        var result = try request(["remote.php"])
        result.url = try documentURL(page: page)
        result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return result
    }
    public func download(page: Page) async throws -> RemoteDocument {
        let (data, response) = try await transport.send(documentRequest(page: page))
        guard response.statusCode == 200 else { throw CollectivesError.http(response.statusCode) }
        guard let markdown = String(data: data, encoding: .utf8) else { throw CollectivesError.invalidResponse }
        return RemoteDocument(markdown: markdown, etag: response.value(forHTTPHeaderField: "ETag"))
    }
    public func downloadImage(at url: URL) async throws -> Data {
        guard ReadingResources.canLoadImage(at: url, account: account) else { throw CollectivesError.unsafeURL }
        var request = try request(["remote.php"])
        request.url = url
        request.setValue("image/png, image/jpeg, image/gif, image/webp, image/heic, image/avif", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw CollectivesError.http(response.statusCode) }
        guard response.url == url,
              let mime = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased(),
              ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/avif"].contains(mime),
              data.count <= 12 * 1_024 * 1_024 else { throw CollectivesError.invalidResponse }
        return data
    }
    public func upload(page: Page, markdown: String, etag: String?) async throws -> String? {
        guard let etag, !etag.isEmpty, !etag.hasPrefix("W/") else { throw CollectivesError.missingETag }
        var request = try documentRequest(page: page)
        request.httpMethod = "PUT"
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        request.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(markdown.utf8)
        let (_, response) = try await transport.send(request)
        if response.statusCode == 412 { throw CollectivesError.conflict }
        guard [200, 204].contains(response.statusCode) else { throw CollectivesError.http(response.statusCode) }
        return response.value(forHTTPHeaderField: "ETag")
    }
}
