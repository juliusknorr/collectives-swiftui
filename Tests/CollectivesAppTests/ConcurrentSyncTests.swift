import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private actor SuspendedDocumentTransport: HTTPTransport {
    private var suspended: CheckedContinuation<Void, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requestStarted = false
    private var suspendNextDocument = true
    private var responseStatus = 200
    private var responseBody = "server changes"

    func waitForDocumentRequest() async {
        if requestStarted { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func suspendNextRequest() {
        requestStarted = false
        suspendNextDocument = true
    }

    func respond(status: Int = 200, body: String = "server changes", suspendNext: Bool = false) {
        responseStatus = status
        responseBody = body
        if suspendNext { suspendNextRequest() }
        suspended?.resume()
        suspended = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/collectives") {
            let body = #"{"ocs":{"meta":{"statuscode":200},"data":{"collectives":[{"id":7,"name":"Team","canEdit":true}]}}}"#
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.path.hasSuffix("/pages") {
            let pages = [70, 71].map {
                """
                {"id":\($0),"title":"Page \($0)","fileName":"\($0).md","filePath":"","collectivePath":"Collectives/Team","parentId":0}
                """
            }.joined(separator: ",")
            let body = """
            {"ocs":{"meta":{"statuscode":200},"data":{"pages":[\(pages)]}}}
            """
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard url.path.contains("/remote.php/dav/files/") else { throw CollectivesError.invalidResponse }
        if suspendNextDocument {
            suspendNextDocument = false
            await withCheckedContinuation { continuation in
                suspended = continuation
                requestStarted = true
                requestWaiter?.resume()
                requestWaiter = nil
            }
        }
        return (Data(responseBody.utf8), HTTPURLResponse(url: url, statusCode: responseStatus,
            httpVersion: nil, headerFields: ["ETag": "\"updated\""])!)
    }
}

@MainActor
private final class ConcurrentSyncFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: LocalStore
    let transport: SuspendedDocumentTransport
    let accounts: [Account]
    let pages: [Page]
    let model: AppModel

    init(draft: String? = nil) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "ConcurrentSyncTests.\(root.lastPathComponent)"
        defaults = UserDefaults(suiteName: suite)!
        store = LocalStore(root: root)
        accounts = ["first", "second"].map {
            Account(serverURL: URL(string: "https://\($0).invalid")!, userID: $0)
        }
        pages = [70, 71].map {
            Page(id: $0, title: "Page \($0)", fileName: "\($0).md", filePath: "",
                 collectivePath: "Collectives/Team")
        }
        let transport = SuspendedDocumentTransport()
        self.transport = transport
        model = AppModel(store: store, preferences: LibraryPreferences(defaults: defaults)) { account in
            CollectivesClient(account: account, credential: Credential(loginName: account.userID, appPassword: "test"),
                transport: transport)
        }
        try await store.saveAccounts(accounts)
        for account in accounts {
            var snapshot = AccountSnapshot()
            snapshot.collectives = [Collective(id: 7, name: "Team", canEdit: true)]
            snapshot.pages["7"] = pages
            for page in pages {
                snapshot.documents[String(page.id)] = CachedDocument(page: page, collectiveID: 7,
                    markdown: "\(account.userID) page \(page.id)", etag: "\"base\"",
                    draft: account.id == accounts[0].id && page.id == 70 ? draft : nil)
            }
            try await store.saveSnapshot(snapshot, accountID: account.id)
        }
        model.accounts = accounts
        model.activeID = accounts[0].id
        model.snapshot = try await store.snapshot(accountID: accounts[0].id)
        model.selectedCollective = 7
        await model.openPage(pages[0])
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Test func manualSyncKeepsEditorAvailableWhileRequestIsSuspended() async throws {
    let fixture = try await ConcurrentSyncFixture()
    defer { fixture.cleanup() }
    let sync = Task { await fixture.model.sync() }
    await fixture.transport.waitForDocumentRequest()
    #expect(fixture.model.syncing)
    #expect(!fixture.model.busy)
    fixture.model.edited("typed while syncing")
    #expect(fixture.model.text == "typed while syncing")
    await fixture.transport.respond()
    await sync.value
    #expect(!fixture.model.syncing)
    #expect(!fixture.model.busy)
}

@MainActor
@Test func uploadResponsePreservesAndPersistsNewerEditorDraft() async throws {
    let fixture = try await ConcurrentSyncFixture(draft: "uploaded draft")
    defer { fixture.cleanup() }
    let sync = Task { await fixture.model.sync() }
    await fixture.transport.waitForDocumentRequest()
    fixture.model.edited("newer draft typed during upload")
    await fixture.transport.respond(status: 204, body: "")
    await sync.value
    #expect(fixture.model.text == "newer draft typed during upload")
    #expect(fixture.model.document?.markdown == "uploaded draft")
    #expect(fixture.model.document?.draft == "newer draft typed during upload")
    #expect(fixture.model.document?.etag == "\"updated\"")
    let saved = try await fixture.store.snapshot(accountID: fixture.accounts[0].id)
    #expect(saved.documents["70"]?.markdown == "uploaded draft")
    #expect(saved.documents["70"]?.draft == "newer draft typed during upload")
}

@MainActor
@Test func navigatingToCachedPageDuringSyncKeepsSelectedPageText() async throws {
    let fixture = try await ConcurrentSyncFixture()
    defer { fixture.cleanup() }
    let sync = Task { await fixture.model.sync() }
    await fixture.transport.waitForDocumentRequest()
    await fixture.model.openPage(fixture.pages[1])
    #expect(fixture.model.selectedPage?.id == 71)
    #expect(fixture.model.text == "first page 71")
    await fixture.transport.respond(body: "updated first page")
    await sync.value
    #expect(fixture.model.selectedPage?.id == 71)
    #expect(fixture.model.text == "first page 71")
    #expect(fixture.model.snapshot.documents["70"]?.markdown == "updated first page")
}

@MainActor
@Test func syncResponseAfterAccountSwitchDoesNotContaminateMatchingPageID() async throws {
    let fixture = try await ConcurrentSyncFixture()
    defer { fixture.cleanup() }
    let sync = Task { await fixture.model.sync() }
    await fixture.transport.waitForDocumentRequest()
    await fixture.model.selectAccount(fixture.accounts[1].id)
    fixture.model.selectedCollective = 7
    await fixture.model.openPage(fixture.pages[0])
    #expect(fixture.model.activeID == fixture.accounts[1].id)
    #expect(fixture.model.text == "second page 70")
    await fixture.transport.respond(body: "first account remote response")
    await sync.value
    #expect(fixture.model.activeID == fixture.accounts[1].id)
    #expect(fixture.model.text == "second page 70")
    #expect(fixture.model.document?.markdown == "second page 70")
    let firstSaved = try await fixture.store.snapshot(accountID: fixture.accounts[0].id)
    let secondSaved = try await fixture.store.snapshot(accountID: fixture.accounts[1].id)
    #expect(firstSaved.documents["70"]?.markdown == "first account remote response")
    #expect(secondSaved.documents["70"]?.markdown == "second page 70")
}

@MainActor
@Test func failedConflictResolutionRetainsLocalDraftAndConflict() async throws {
    let fixture = try await ConcurrentSyncFixture(draft: "precious draft")
    defer { fixture.cleanup() }
    let remote = RemoteDocument(markdown: "server copy", etag: "\"server\"")
    fixture.model.snapshot.documents["70"]?.conflict = remote
    try FileManager.default.removeItem(at: fixture.root)
    try Data().write(to: fixture.root)

    await fixture.model.resolveConflict(useServer: true)
    #expect(fixture.model.document?.draft == "precious draft")
    #expect(fixture.model.document?.conflict == remote)
    #expect(fixture.model.document?.markdown == "first page 70")
    #expect(fixture.model.text == "precious draft")
    #expect(!fixture.model.busy)
}

@MainActor
@Test func unauthorizedSyncOffersSignInAndRetainsCachedContent() async throws {
    let fixture = try await ConcurrentSyncFixture()
    defer { fixture.cleanup() }
    let sync = Task { await fixture.model.sync() }
    await fixture.transport.waitForDocumentRequest()
    await fixture.transport.respond(status: 401, body: "")
    await sync.value
    #expect(fixture.model.syncIssues[fixture.accounts[0].id]?.requiresSignIn == true)
    #expect(fixture.model.text == "first page 70")
    #expect(fixture.model.document?.markdown == "first page 70")
    #expect(!fixture.model.syncing)

    await fixture.transport.suspendNextRequest()
    let retry = Task { await fixture.model.sync() }
    await fixture.transport.waitForDocumentRequest()
    await fixture.transport.respond(body: "content after signing in again")
    await retry.value
    #expect(fixture.model.syncIssues[fixture.accounts[0].id] == nil)
    #expect(fixture.model.text == "content after signing in again")
}

@MainActor
@Test func fullAutomaticSyncPreservesEditsAcrossDocumentCheckpoints() async throws {
    let fixture = try await ConcurrentSyncFixture()
    defer { fixture.cleanup() }
    let sync = Task { await fixture.model.syncAccounts(automatic: true) }
    await fixture.transport.waitForDocumentRequest()
    #expect(fixture.model.syncing)
    #expect(!fixture.model.busy)
    fixture.model.edited("draft typed during account refresh")
    await fixture.transport.respond(body: "refreshed server copy", suspendNext: true)
    await fixture.transport.waitForDocumentRequest()

    // The second document request starts after the first document's checkpoint is saved.
    #expect(!fixture.model.busy)
    #expect(fixture.model.text == "draft typed during account refresh")
    #expect(fixture.model.document?.draft == "draft typed during account refresh")
    let competingRemote = RemoteDocument(markdown: "refreshed server copy", etag: "\"updated\"")
    #expect(fixture.model.document?.markdown == "first page 70")
    #expect(fixture.model.document?.etag == "\"base\"")
    #expect(fixture.model.document?.conflict == competingRemote)
    let checkpoint = try await fixture.store.snapshot(accountID: fixture.accounts[0].id)
    #expect(checkpoint.documents["70"]?.draft == "draft typed during account refresh")
    #expect(checkpoint.documents["70"]?.markdown == "first page 70")
    #expect(checkpoint.documents["70"]?.etag == "\"base\"")
    #expect(checkpoint.documents["70"]?.conflict == competingRemote)

    await fixture.transport.respond(body: "second document server copy")
    #expect(await sync.value)
    #expect(!fixture.model.syncing)
    #expect(!fixture.model.busy)
    #expect(fixture.model.text == "draft typed during account refresh")
    #expect(fixture.model.document?.markdown == "first page 70")
    #expect(fixture.model.document?.etag == "\"base\"")
    #expect(fixture.model.document?.conflict == competingRemote)
    let saved = try await fixture.store.snapshot(accountID: fixture.accounts[0].id)
    #expect(saved.documents["70"]?.draft == "draft typed during account refresh")
    #expect(saved.documents["70"]?.markdown == "first page 70")
    #expect(saved.documents["70"]?.etag == "\"base\"")
    #expect(saved.documents["70"]?.conflict == competingRemote)
    #expect(saved.documents["71"]?.markdown == "second document server copy")
}

@MainActor
@Test(arguments: [false, true])
func resolvingConflictPersistsChosenVersion(useServer: Bool) async throws {
    let fixture = try await ConcurrentSyncFixture(draft: "my local draft")
    defer { fixture.cleanup() }
    fixture.model.snapshot.documents["70"]?.conflict = RemoteDocument(markdown: "reviewed server copy", etag: "\"reviewed\"")

    await fixture.model.resolveConflict(useServer: useServer)

    let expectedDraft: String? = useServer ? nil : "my local draft"
    #expect(fixture.model.document?.conflict == nil)
    #expect(fixture.model.document?.markdown == "reviewed server copy")
    #expect(fixture.model.document?.etag == "\"reviewed\"")
    #expect(fixture.model.document?.draft == expectedDraft)
    #expect(fixture.model.text == (useServer ? "reviewed server copy" : "my local draft"))
    let saved = try await fixture.store.snapshot(accountID: fixture.accounts[0].id)
    #expect(saved.documents["70"]?.conflict == nil)
    #expect(saved.documents["70"]?.draft == expectedDraft)
    #expect(saved.documents["70"]?.markdown == "reviewed server copy")
    #expect(saved.documents["70"]?.etag == "\"reviewed\"")
}
