import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private actor StartupTransport: HTTPTransport {
    private var content = "original"
    private var revision = "\"base\""
    private var rejectUploads = false
    private(set) var requests: [URLRequest] = []
    private(set) var documentResponses: [Int] = []

    func changeContent(_ content: String, rejectUploads: Bool = false) {
        self.content = content
        revision = "\"changed\""
        self.rejectUploads = rejectUploads
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        var status = 200
        var headers: [String: String] = [:]
        let body: String
        if url.path.hasSuffix("/collectives") {
            body = #"{"ocs":{"meta":{"statuscode":200},"data":{"collectives":[{"id":7,"name":"Team","canEdit":true},{"id":8,"name":"Other","canEdit":true}]}}}"#
        } else if url.path.hasSuffix("/pages") {
            let collectiveID = url.pathComponents.dropLast().last!
            let pageID = collectiveID == "7" ? 70 : 80
            body = """
            {"ocs":{"meta":{"statuscode":200},"data":{"pages":[{"id":\(pageID),"title":"Notes","fileName":"\(pageID).md","filePath":"","collectivePath":"Collectives/Team","parentId":0}]}}}
            """
        } else if url.path.contains("/remote.php/dav/files/") {
            headers["ETag"] = revision
            if request.httpMethod == "PUT" {
                status = rejectUploads ? 412 : 204
                body = ""
            } else if request.value(forHTTPHeaderField: "If-None-Match") == revision {
                status = 304
                body = ""
            } else {
                body = "\(url.host!) \(content) \(url.lastPathComponent)"
            }
            documentResponses.append(status)
        } else {
            throw CollectivesError.invalidResponse
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

@MainActor
private final class StartupFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: LocalStore
    let transport: StartupTransport
    let accounts: [Account]
    let model: AppModel

    init(accountCount: Int = 1) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.root = root
        suite = "StartupSyncTests.\(root.lastPathComponent)"
        let defaults = UserDefaults(suiteName: suite)!
        self.defaults = defaults
        let store = LocalStore(root: root)
        self.store = store
        let transport = StartupTransport()
        self.transport = transport
        accounts = (1...accountCount).map {
            Account(serverURL: URL(string: "https://account\($0).invalid")!, userID: "user\($0)")
        }
        try await store.saveAccounts(accounts)
        model = AppModel(store: store, preferences: LibraryPreferences(defaults: defaults)) { account in
            CollectivesClient(account: account, credential: Credential(loginName: account.userID, appPassword: "test"),
                transport: transport)
        }
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Test func startupSynchronizesEveryPageOfEveryAccountAndPersistsOfflineContent() async throws {
    let fixture = try await StartupFixture(accountCount: 2)
    defer { fixture.cleanup() }
    await fixture.model.start()
    #expect(fixture.model.startupComplete)
    #expect(fixture.model.syncActivity == nil)
    for account in fixture.accounts {
        let saved = try await fixture.store.snapshot(accountID: account.id)
        #expect(saved.collectives.map(\.id) == [7, 8])
        #expect(saved.pages["7"]?.map(\.id) == [70])
        #expect(saved.pages["8"]?.map(\.id) == [80])
        #expect(saved.documents["70"]?.markdown == "\(account.serverURL.host!) original 70.md")
        #expect(saved.documents["80"]?.markdown == "\(account.serverURL.host!) original 80.md")
        #expect(fixture.model.collectives(for: account.id).count == 2)
    }
    #expect(await fixture.transport.documentResponses == [200, 200, 200, 200])
    let requestCount = await fixture.transport.requests.count
    await fixture.model.start()
    #expect(await fixture.transport.requests.count == requestCount)
}

@MainActor
@Test func repeatedAccountSyncUsesConditionalDownloadsAndUpdatesSelectedText() async throws {
    let fixture = try await StartupFixture()
    defer { fixture.cleanup() }
    await fixture.model.start()
    fixture.model.selectedCollective = 7
    await fixture.model.openPage(fixture.model.snapshot.pages["7"]![0])
    #expect(fixture.model.text == "account1.invalid original 70.md")

    #expect(await fixture.model.syncAccounts(automatic: true))
    #expect(await fixture.transport.documentResponses == [200, 200, 304, 304])
    #expect(fixture.model.text == "account1.invalid original 70.md")
    await fixture.transport.changeContent("new content")
    #expect(await fixture.model.syncAccounts(automatic: true))
    #expect(fixture.model.text == "account1.invalid new content 70.md")
    #expect(fixture.model.document?.etag == "\"changed\"")
    let saved = try await fixture.store.snapshot(accountID: fixture.accounts[0].id)
    #expect(saved.documents["70"]?.markdown == fixture.model.text)
    let documentRequests = await fixture.transport.requests.filter { $0.url!.path.contains("/dav/files/") }
    #expect(documentRequests.dropFirst(2).allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == "\"base\"" })
}

@MainActor
@Test func accountSyncFlushesEditorDraftAndPreservesItWhenServerChanged() async throws {
    let fixture = try await StartupFixture()
    defer { fixture.cleanup() }
    await fixture.model.start()
    fixture.model.selectedCollective = 7
    await fixture.model.openPage(fixture.model.snapshot.pages["7"]![0])
    fixture.model.edited("local edit")
    await fixture.transport.changeContent("competing edit", rejectUploads: true)
    #expect(await fixture.model.syncAccounts())
    #expect(fixture.model.text == "local edit")
    #expect(fixture.model.document?.draft == "local edit")
    #expect(fixture.model.document?.conflict?.markdown == "account1.invalid competing edit 70.md")
    let saved = try await fixture.store.snapshot(accountID: fixture.accounts[0].id)
    #expect(saved.documents["70"]?.draft == "local edit")
    #expect(saved.documents["70"]?.etag == "\"base\"")
    #expect(saved.documents["70"]?.conflict?.etag == "\"changed\"")
    let uploads = await fixture.transport.requests.filter { $0.httpMethod == "PUT" }
    #expect(uploads.count == 1)
    #expect(uploads.first?.value(forHTTPHeaderField: "If-Match") == "\"base\"")
}

@MainActor
@Test func startupKeepsDeletedCollectiveWithDraftVisibleWithoutUploadingDeletedPage() async throws {
    let fixture = try await StartupFixture()
    defer { fixture.cleanup() }
    let deletedPage = Page(id: 90, title: "Deleted page", fileName: "90.md", filePath: "",
        collectivePath: "Collectives/Deleted")
    var cached = AccountSnapshot()
    cached.collectives = [Collective(id: 9, name: "Deleted collective")]
    cached.pages["9"] = [deletedPage]
    cached.documents["90"] = CachedDocument(page: deletedPage, collectiveID: 9,
        markdown: "base", etag: "\"base\"", draft: "unsynced draft")
    try await fixture.store.saveSnapshot(cached, accountID: fixture.accounts[0].id)

    await fixture.model.start()
    #expect(fixture.model.collectives(for: fixture.accounts[0].id).contains { $0.id == 9 })
    #expect(fixture.model.snapshot.pages["9"] == [deletedPage])
    #expect(fixture.model.snapshot.documents["90"]?.draft == "unsynced draft")
    let saved = try await fixture.store.snapshot(accountID: fixture.accounts[0].id)
    #expect(saved.collectives.contains { $0.id == 9 })
    #expect(saved.documents["90"]?.draft == "unsynced draft")
    #expect(await fixture.transport.requests.allSatisfy { $0.httpMethod != "PUT" })
    #expect(await fixture.transport.requests.allSatisfy { $0.url?.lastPathComponent != "90.md" })
}

@MainActor
@Test func clientsAreCreatedOncePerAccount() async throws {
    let fixture = try await StartupFixture(accountCount: 2)
    defer { fixture.cleanup() }
    var created: [UUID] = []
    let model = AppModel(store: fixture.store, preferences: LibraryPreferences(defaults: fixture.defaults)) { account in
        created.append(account.id)
        return CollectivesClient(account: account, credential: Credential(loginName: account.userID, appPassword: "test"),
            transport: fixture.transport)
    }
    await model.start()
    #expect(await model.syncAccounts())
    _ = try model.client()
    #expect(created.sorted { $0.uuidString < $1.uuidString } == fixture.accounts.map(\.id).sorted { $0.uuidString < $1.uuidString })
}
