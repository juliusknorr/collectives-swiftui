import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

@MainActor
private final class WindowFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "WindowCoordinationTests.\(UUID().uuidString)")!
    let store: LocalStore
    let first: AppModel
    let second: AppModel
    let account = Account(serverURL: URL(string: "https://cloud.invalid")!, userID: "alice")
    let pages = (1...2).map { Page(id: $0, title: "Page \($0)", fileName: "\($0).md", filePath: "", collectivePath: "Collectives/Team") }

    init(transport: any HTTPTransport = URLSessionTransport()) async throws {
        store = LocalStore(root: root)
        first = AppModel(store: store, preferences: LibraryPreferences(defaults: defaults),
                         modePreferences: PageModePreferences(defaults: defaults), makeClient: { account in
            CollectivesClient(account: account, credential: Credential(loginName: "alice", appPassword: "secret"), transport: transport)
        })
        second = first.newWindow()
        try await store.saveAccounts([account])
        first.accounts = [account]
        first.activeID = account.id
        second.activeID = account.id
        var snapshot = AccountSnapshot()
        snapshot.collectives = [Collective(id: 7, name: "Team", canEdit: true)]
        snapshot.pages["7"] = pages
        for page in pages {
            snapshot.documents[String(page.id)] = CachedDocument(page: page, collectiveID: 7, markdown: "base \(page.id)", etag: "\"base\"")
        }
        first.snapshot = snapshot
        try await store.saveSnapshot(snapshot, accountID: account.id)
        first.selectedCollective = 7
        second.selectedCollective = 7
        await first.openPage(pages[0])
        await second.openPage(pages[0])
    }
    func cleanup() {
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Test
func windowsNavigateIndependentlyAndShareDrafts() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    await f.first.changePageMode(.edit)
    f.first.edited("first page draft")
    #expect(f.second.text == "first page draft")
    await f.second.openPage(f.pages[1])
    #expect(f.first.selectedPage?.id == 1)
    #expect(f.first.text == "first page draft")
    #expect(f.second.selectedPage?.id == 2)
    await f.second.changePageMode(.edit)
    f.second.edited("second page draft")
    f.first.edited("newer first draft")
    await f.first.pendingPersistence?.value
    let saved = try await f.store.snapshot(accountID: f.account.id)
    #expect(saved.documents["1"]?.draft == "newer first draft")
    #expect(saved.documents["2"]?.draft == "second page draft")
    #expect(f.second.text == "second page draft")
}

@MainActor @Test
func anotherWindowCannotOverwriteOwnedPageAndCanTakeOverAfterView() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    await f.first.changePageMode(.edit)
    f.first.edited("precious draft")
    await f.second.changePageMode(.edit)
    #expect(f.second.pageMode == .view)
    #expect(f.second.editingInAnotherWindow)
    f.second.edited("stale editor value")
    #expect(f.first.document?.draft == "precious draft")
    #expect(f.second.message.contains("another window"))
    await f.first.changePageMode(.view)
    await f.second.changePageMode(.edit)
    #expect(!f.second.editingInAnotherWindow)
    f.second.edited("continued draft")
    #expect(f.first.text == "continued draft")
    #expect(f.first.document?.etag == "\"base\"")
    #expect(f.first.document?.markdown == "base 1")
    await f.second.pendingPersistence?.value
    #expect(try await f.store.snapshot(accountID: f.account.id).documents["1"]?.draft == "continued draft")
}

@MainActor @Test
func sharedSnapshotUpdatesOtherWindowWithoutChangingItsSelection() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    await f.second.openPage(f.pages[1])
    var remote = f.first.snapshot
    remote.documents["2"]?.markdown = "downloaded server text"
    remote.documents["2"]?.etag = "\"new\""
    f.first.snapshot = remote
    #expect(f.second.selectedPage?.id == 2)
    #expect(f.second.text == "downloaded server text")
    #expect(f.first.selectedPage?.id == 1)
}

@MainActor @Test
func richEditorInAnotherWindowBlocksNativeSync() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    f.first.textSession = EmbeddedTextSession(accountID: f.account.id, pageID: 1, markdown: "base 1")
    #expect(f.second.session.hasRichTextEditor)
    #expect(await f.second.syncAccounts() == false)
    await f.second.syncPending()
    #expect(!f.second.syncing)
    f.first.textSession = nil
}

@MainActor @Test
func openingAnotherWindowUsesCurrentUnsavedSnapshot() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    await f.first.changePageMode(.edit)
    f.first.edited("latest shared draft")
    f.first.started = true
    let third = f.first.newWindow()
    await third.start()
    #expect(third.text == "latest shared draft")
    #expect(third.document?.etag == "\"base\"")
    #expect(third.editingInAnotherWindow)
    #expect(f.first.text == "latest shared draft")
    await f.first.pendingPersistence?.value
}

@MainActor @Test
func favoritesAndRecentPagesAreSharedWithoutChangingWindowNavigation() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    f.first.toggleFavorite(1)
    f.second.toggleFavorite(2)
    #expect(f.first.library.favoritePageIDs == [1, 2])
    #expect(f.second.library.favoritePageIDs == [1, 2])
    await f.second.openPage(f.pages[1])
    #expect(f.first.selectedPage?.id == 1)
    #expect(f.first.library.recentPageIDs.first == 2)
    let preferences = LibraryPreferences(defaults: f.defaults)
    #expect(preferences.load(accountID: f.account.id).favoritePageIDs == [1, 2])
}

@MainActor @Test
func staleSourceEditorCallbacksCannotEditTheNewPageOrViewedPage() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    await f.first.changePageMode(.edit)
    f.first.edited("original page draft", accountID: f.account.id, pageID: 1)
    await f.first.openPage(f.pages[1])
    await f.first.changePageMode(.edit)
    f.first.edited("late previous editor value", accountID: f.account.id, pageID: 1)
    #expect(f.first.text == "base 2")
    #expect(f.first.snapshot.documents["1"]?.draft == "original page draft")
    #expect(f.first.snapshot.documents["2"]?.draft == nil)
    f.first.edited("wrong account", accountID: UUID(), pageID: 2)
    #expect(f.first.text == "base 2")
    await f.first.changePageMode(.view)
    f.first.edited("late callback after View", accountID: f.account.id, pageID: 2)
    #expect(f.first.text == "base 2")
}

private actor WindowSyncTransport: HTTPTransport {
    private var response: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func waitForRequest() async {
        if response != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func complete() { response?.resume(); response = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { continuation in
            response = continuation
            waiter?.resume(); waiter = nil
        }
        return (Data("server update".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["ETag": "\"updated\""])!)
    }
}

@MainActor @Test
func syncingOneWindowPreservesTypingInAnotherWindow() async throws {
    let transport = WindowSyncTransport()
    let f = try await WindowFixture(transport: transport)
    defer { f.cleanup() }
    await f.second.openPage(f.pages[1])
    await f.second.changePageMode(.edit)
    let sync = Task { await f.first.sync() }
    await transport.waitForRequest()
    f.second.edited("typed in second window while syncing")
    await transport.complete()
    await sync.value
    #expect(f.first.text == "server update")
    #expect(f.second.selectedPage?.id == 2)
    #expect(f.second.text == "typed in second window while syncing")
    let saved = try await f.store.snapshot(accountID: f.account.id)
    #expect(saved.documents["1"]?.etag == "\"updated\"")
    #expect(saved.documents["2"]?.draft == "typed in second window while syncing")
}

private actor WindowCollectivesTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = #"{"ocs":{"meta":{"statuscode":200},"data":{"collectives":[{"id":7,"name":"Updated","canEdit":false}]}}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Test
func refreshingAnotherAccountsCollectivesUpdatesItsOpenWindow() async throws {
    let f = try await WindowFixture(transport: WindowCollectivesTransport())
    defer { f.cleanup() }
    let other = Account(serverURL: URL(string: "https://other.invalid")!, userID: "bob")
    f.first.accounts.append(other)
    f.second.activeID = other.id
    f.second.snapshot = f.first.snapshot
    try await f.store.saveSnapshot(f.second.snapshot, accountID: other.id)
    await f.first.refresh(excludingActive: true)
    #expect(f.second.snapshot.collectives.first?.name == "Updated")
    #expect(!f.second.canEdit)
    #expect(f.second.selectedPage?.id == 1)
    try await f.second.persist()
    #expect(try await f.store.snapshot(accountID: other.id).collectives.first?.name == "Updated")
}

@MainActor @Test
func startingWindowDuringOperationWaitsBeforeRestoringSelection() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    f.first.started = true
    f.first.busy = true
    let third = f.first.newWindow()
    let startup = Task { await third.start() }
    await Task.yield()
    #expect(third.activeID == nil)
    f.first.busy = false
    await startup.value
    #expect(third.activeID == f.account.id)
    #expect(third.selectedPage?.id == 1)
}

@MainActor @Test
func sourceEditorGenerationRejectsCallbacksAfterReopeningSamePage() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    await f.first.changePageMode(.edit)
    let generation = f.first.sourceEditorGeneration
    await f.first.openPage(f.pages[1])
    await f.first.openPage(f.pages[0])
    await f.first.changePageMode(.edit)
    f.first.edited("current draft", accountID: f.account.id, pageID: 1, editorGeneration: f.first.sourceEditorGeneration)
    f.first.edited("obsolete editor", accountID: f.account.id, pageID: 1, editorGeneration: generation)
    #expect(f.first.text == "current draft")
    await f.first.pendingPersistence?.value
}

@MainActor @Test
func unrelatedSuccessfulSaveCannotHideAnotherWindowsUndurableDraft() async throws {
    let f = try await WindowFixture()
    defer { f.cleanup() }
    let other = Account(serverURL: URL(string: "https://other.invalid")!, userID: "bob")
    f.first.accounts.append(other)
    f.second.activeID = other.id
    f.second.snapshot = f.first.snapshot
    try await f.store.saveSnapshot(f.second.snapshot, accountID: other.id)
    await f.first.changePageMode(.edit)
    await f.second.changePageMode(.edit)
    let documents = f.root.appendingPathComponent(f.account.id.uuidString).appendingPathComponent("documents")
    let retained = f.root.appendingPathComponent("retained-documents")
    try FileManager.default.moveItem(at: documents, to: retained)
    try Data("blocks directory creation".utf8).write(to: documents)
    f.first.edited("draft that cannot be saved")
    await f.first.pendingPersistence?.value
    #expect(f.first.draftSaveFailed)
    f.second.edited("other account saved draft")
    await f.second.pendingPersistence?.value
    #expect(f.second.draftSaveFailed)
    #expect(f.first.snapshot.documents["1"]?.draft == "draft that cannot be saved")
    #expect(try await f.store.snapshot(accountID: other.id).documents["1"]?.draft == "other account saved draft")
    try FileManager.default.removeItem(at: documents)
    try FileManager.default.moveItem(at: retained, to: documents)
    f.second.edited("retry after storage recovers")
    await f.second.pendingPersistence?.value
    #expect(!f.first.draftSaveFailed)
    let reopened = LocalStore(root: f.root)
    #expect(try await reopened.snapshot(accountID: f.account.id).documents["1"]?.draft == "draft that cannot be saved")
    #expect(try await reopened.snapshot(accountID: other.id).documents["1"]?.draft == "retry after storage recovers")
}
