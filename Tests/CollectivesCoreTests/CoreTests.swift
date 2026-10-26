import Foundation
import Testing
@testable import CollectivesCore

private actor StubTransport: HTTPTransport {
    private var responses: [(Int, String, [String: String])]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [(Int, String, [String: String])]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        return (Data(response.1.utf8), HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: response.2)!)
    }
}
private let server = URL(string: "https://cloud.example.test/nextcloud")!
private let page = Page(id: 42, title: "Notes", fileName: "Notes #1.md", filePath: "Projects", collectivePath: "Collectives/Team 📚")

@Test func serverValidationAndBoundaries() throws {
    #expect(try ServerAddress.normalize(URL(string: "http://localhost:8080/")!).absoluteString == "http://localhost:8080")
    #expect(throws: CollectivesError.self) { try ServerAddress.normalize(URL(string: "http://cloud.example.test")!) }
    #expect(throws: CollectivesError.self) { try ServerAddress.normalize(URL(string: "https://user:secret@cloud.example.test")!) }
    #expect(!ServerAddress.isTrusted(URL(string: "https://cloud.example.test.evil/nextcloud")!, server: server))
    #expect(!ServerAddress.isTrusted(URL(string: "https://cloud.example.test/nextcloud-other")!, server: server))
    #expect(!ServerAddress.isTrusted(URL(string: "https://cloud.example.test/nextcloud/../other")!, server: server))
    #expect(!ServerAddress.isTrusted(URL(string: "https://cloud.example.test:8443/nextcloud")!, server: server))
}

@Test func loginFlowWaitsAndEncodesToken() async throws {
    let transport = StubTransport([
        (200, "{\"login\":\"https://cloud.example.test/nextcloud/login/v2/flow/abc\",\"poll\":{\"token\":\"a+b&c\",\"endpoint\":\"https://cloud.example.test/nextcloud/login/v2/poll\"}}", [:]),
        (404, "", [:]),
        (200, "{\"server\":\"https://cloud.example.test/nextcloud\",\"loginName\":\"alice@example.test\",\"appPassword\":\"secret\"}", [:])
    ])
    let client = LoginFlowClient(transport: transport)
    let flow = try await client.begin(serverURL: server)
    #expect(try await client.poll(flow, serverURL: server) == nil)
    let credentials = try await client.poll(flow, serverURL: server)
    #expect(credentials?.loginName == "alice@example.test")
    let requests = await transport.requests
    #expect(requests[0].url?.path == "/nextcloud/index.php/login/v2")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(String(data: requests[1].httpBody!, encoding: .utf8) == "token=a%2Bb%26c")
}

@Test func loginRejectsUntrustedPollEndpoint() async throws {
    let transport = StubTransport([(200, "{\"login\":\"https://cloud.example.test/nextcloud/login\",\"poll\":{\"token\":\"secret\",\"endpoint\":\"https://evil.example/poll\"}}", [:])])
    await #expect(throws: CollectivesError.self) { try await LoginFlowClient(transport: transport).begin(serverURL: server) }
    #expect(await transport.requests.count == 1)
}

@Test func apiUsesOCSEnvelopesAndCanonicalUID() async throws {
    let transport = StubTransport([
        (200, "{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":{\"id\":\"alice\"}}}", [:]),
        (200, "{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":{\"collectives\":[{\"id\":1,\"name\":\"Team\",\"canEdit\":true}]}}}", [:]),
        (200, "{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":{\"pages\":[{\"id\":42,\"title\":\"Notes\",\"fileName\":\"Notes.md\",\"filePath\":\"Projects\",\"collectivePath\":\"Collectives/Team\",\"parentId\":0}]}}}", [:])
    ])
    let client = CollectivesClient(account: Account(serverURL: server, userID: "alice"), credential: Credential(loginName: "alice@example.test", appPassword: "secret"), transport: transport)
    #expect(try await client.currentUserID() == "alice")
    #expect(try await client.collectives().first?.name == "Team")
    #expect(try await client.pages(collectiveID: 1).first?.id == 42)
    let url = try client.documentURL(page: page)
    #expect(url.path == "/nextcloud/remote.php/dav/files/alice/Collectives/Team 📚/Projects/Notes #1.md")
    let invalid = Page(id: 1, title: "", fileName: "x.md", filePath: "../private", collectivePath: "Collectives/Team")
    #expect(throws: CollectivesError.self) { try client.documentURL(page: invalid) }
}

@Test func webDAVRequiresBaseRevisionAndPreservesConflict() async throws {
    let transport = StubTransport([(200, "# Original", ["ETag": "\"base\""]), (412, "", [:])])
    let client = CollectivesClient(account: Account(serverURL: server, userID: "alice"), credential: Credential(loginName: "alice", appPassword: "secret"), transport: transport)
    let remote = try await client.download(page: page)
    #expect(remote.markdown == "# Original")
    await #expect(throws: CollectivesError.self) { try await client.upload(page: page, markdown: "# Draft", etag: nil) }
    await #expect(throws: CollectivesError.self) { try await client.upload(page: page, markdown: "# Draft", etag: remote.etag) }
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[1].httpMethod == "PUT")
    #expect(requests[1].value(forHTTPHeaderField: "If-Match") == "\"base\"")
}

@Test func localDraftSurvivesRestartAndAccountsStayIsolated() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = Account(serverURL: server, userID: "alice")
    let other = Account(serverURL: server, userID: "bob")
    let store = LocalStore(root: root)
    try await store.saveAccounts([account, other])
    var snapshot = AccountSnapshot()
    snapshot.documents["42"] = CachedDocument(page: page, collectiveID: 1, markdown: "base", etag: "\"base\"", draft: "local draft", conflict: RemoteDocument(markdown: "remote change", etag: "\"remote\""))
    try await store.saveSnapshot(snapshot, accountID: account.id)
    let restarted = LocalStore(root: root)
    #expect(try await restarted.accounts().count == 2)
    let restored = try await restarted.snapshot(accountID: account.id)
    #expect(restored.documents["42"]?.draft == "local draft")
    #expect(restored.documents["42"]?.etag == "\"base\"")
    #expect(restored.documents["42"]?.conflict?.markdown == "remote change")
    #expect(try await restarted.snapshot(accountID: other.id).documents.isEmpty)
}

@Test func uploadReturnsNewRevisionAndRejectsWeakRevision() async throws {
    let transport = StubTransport([(204, "", ["ETag": "\"new\""])])
    let client = CollectivesClient(account: Account(serverURL: server, userID: "alice"), credential: Credential(loginName: "alice", appPassword: "secret"), transport: transport)
    await #expect(throws: CollectivesError.self) { try await client.upload(page: page, markdown: "changed", etag: "W/\"base\"") }
    #expect(try await client.upload(page: page, markdown: "changed", etag: "\"base\"") == "\"new\"")
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    #expect(String(data: requests[0].httpBody!, encoding: .utf8) == "changed")
}

@Test func loginRejectsCredentialServerChanges() async throws {
    let transport = StubTransport([
        (200, "{\"login\":\"https://cloud.example.test/nextcloud/login/v2/flow/a\",\"poll\":{\"token\":\"token\",\"endpoint\":\"https://cloud.example.test/nextcloud/login/v2/poll\"}}", [:]),
        (200, "{\"server\":\"https://evil.example\",\"loginName\":\"alice\",\"appPassword\":\"secret\"}", [:])
    ])
    let client = LoginFlowClient(transport: transport)
    let flow = try await client.begin(serverURL: server)
    await #expect(throws: CollectivesError.self) { try await client.poll(flow, serverURL: server) }
}

@Test func pageEmojisDecodeAndSurviveOfflineStorage() async throws {
    let withEmoji = Data(#"{"id":9,"title":"Ideas","emoji":"💡","fileName":"Ideas.md","filePath":"","collectivePath":"Collectives/Team","parentId":0}"#.utf8)
    let withoutEmoji = Data(#"{"id":10,"title":"Notes","fileName":"Notes.md","filePath":"","parentId":9}"#.utf8)
    let page = try JSONDecoder().decode(Page.self, from: withEmoji)
    #expect(page.emoji == "💡")
    #expect(try JSONDecoder().decode(Page.self, from: withoutEmoji).emoji == nil)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let store = LocalStore(root: root)
    var snapshot = AccountSnapshot()
    snapshot.pages["1"] = [page]
    snapshot.documents["9"] = CachedDocument(page: page, collectiveID: 1, markdown: "# Ideas", etag: "base", draft: "# Offline ideas")
    try await store.saveSnapshot(snapshot, accountID: accountID)
    let loaded = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(loaded.pages["1"]?.first?.emoji == "💡")
    #expect(loaded.documents["9"]?.page.emoji == "💡")
    #expect(loaded.documents["9"]?.draft == "# Offline ideas")
}

@Test func pageEmojiUpdatesUseJSONAndDecodeMetadata() async throws {
    let updated = #"{"ocs":{"meta":{"statuscode":200},"data":{"page":{"id":42,"title":"Notes","emoji":"💡","fileName":"Notes.md","filePath":"","parentId":0,"timestamp":1700000000,"lastUserDisplayName":"Alice"}}}}"#
    let removed = #"{"ocs":{"meta":{"statuscode":200},"data":{"page":{"id":42,"title":"Notes","emoji":null,"fileName":"Notes.md","filePath":"","parentId":0}}}}"#
    let transport = StubTransport([(200, updated, [:]), (200, removed, [:])])
    let client = CollectivesClient(account: Account(serverURL: server, userID: "alice"), credential: Credential(loginName: "alice", appPassword: "secret"), transport: transport)
    let page = try await client.setPageEmoji(pageID: 42, collectiveID: 1, emoji: "💡")
    #expect(page.emoji == "💡")
    #expect(page.timestamp == 1700000000)
    #expect(page.lastUserDisplayName == "Alice")
    #expect(try await client.setPageEmoji(pageID: 42, collectiveID: 1, emoji: nil).emoji == nil)
    let requests = await transport.requests
    #expect(requests[0].httpMethod == "PUT")
    #expect(requests[0].url?.path == "/nextcloud/ocs/v2.php/apps/collectives/api/v1.0/collectives/1/pages/42/emoji")
    #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: String]
    #expect(body["emoji"] == "💡")
    let cleared = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
    #expect(cleared["emoji"] is NSNull)
}

@Test func pageCreationPostsEncodedTitleToRequestedParent() async throws {
    let response = #"{"ocs":{"meta":{"statuscode":200},"data":{"page":{"id":43,"title":"Ideas & 🌱","fileName":"Ideas & 🌱.md","filePath":"Notes","parentId":42,"collectivePath":"Collectives/Team"}}}}"#
    let transport = StubTransport([(200, response, [:])])
    let client = CollectivesClient(account: Account(serverURL: server, userID: "alice"), credential: Credential(loginName: "alice", appPassword: "secret"), transport: transport)
    let created = try await client.createPage(collectiveID: 3, parentID: 42, title: " Ideas & 🌱 ")
    #expect(created.parentId == 42)
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].httpMethod == "POST")
    #expect(requests[0].url?.path == "/nextcloud/ocs/v2.php/apps/collectives/api/v1.0/collectives/3/pages/42")
    #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(try JSONDecoder().decode([String: String].self, from: requests[0].httpBody!) == ["title": "Ideas & 🌱"])
}
