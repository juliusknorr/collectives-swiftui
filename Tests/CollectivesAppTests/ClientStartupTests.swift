import Foundation
import Security
import Testing
import CollectivesCore
@testable import CollectivesApp

private actor CredentialGate {
    private var entered = false
    private var release: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    func suspend() async {
        calls += 1
        guard calls == 1 else { return }
        entered = true
        observers.forEach { $0.resume() }
        observers = []
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { release?.resume(); release = nil }
}

private struct OfflineStartupTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
@Test func startupRestoresCachedNoteBeforeCredentialsAndReusesPreparedClient() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "ClientStartupTests.\(root.lastPathComponent)")!
    defer { defaults.removePersistentDomain(forName: "ClientStartupTests.\(root.lastPathComponent)") }
    let preferences = LibraryPreferences(defaults: defaults)
    let store = LocalStore(root: root)
    let account = Account(serverURL: URL(string: "https://startup.invalid")!, userID: "test")
    let page = Page(id: 70, title: "Cached note", fileName: "note.md", filePath: "note.md", collectivePath: nil)
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 7, name: "Cached collective")]
    snapshot.pages["7"] = [page]
    snapshot.documents["70"] = CachedDocument(page: page, collectiveID: 7, markdown: "Cached content", etag: "base")
    try await store.saveAccounts([account])
    try await store.saveSnapshot(snapshot, accountID: account.id)
    var selection = PageLibraryState()
    selection.visit(pageID: page.id, collectiveID: 7)
    preferences.save(selection, accountID: account.id)
    preferences.lastAccountID = account.id
    let gate = CredentialGate()
    let model = AppModel(store: store, preferences: preferences, modePreferences: PageModePreferences(defaults: defaults)) { account in
        await gate.suspend()
        return CollectivesClient(account: account, credential: Credential(loginName: "test", appPassword: "test"),
                                 transport: OfflineStartupTransport())
    }
    let startup = Task { await model.start() }
    await gate.waitUntilEntered()
    #expect(model.activeID == account.id)
    #expect(model.selectedCollective == 7)
    #expect(model.selectedPage?.id == page.id)
    #expect(model.text == "Cached content")
    #expect(!model.startupComplete)
    await gate.resume()
    await startup.value
    #expect(model.startupComplete)
    await model.refresh()
    #expect(await gate.calls == 1)
    #expect(model.text == "Cached content")

    defaults.set(PageViewMode.richText.rawValue, forKey: "defaultPageMode")
    let richModel = AppModel(store: store, preferences: preferences, modePreferences: PageModePreferences(defaults: defaults)) { account in
        await gate.suspend()
        return CollectivesClient(account: account, credential: Credential(loginName: "test", appPassword: "test"),
                                 transport: OfflineStartupTransport())
    }
    await richModel.start()
    #expect(richModel.startupComplete)
    #expect(richModel.selectedPage?.id == page.id)
    #expect(richModel.textSession?.initialMarkdown == "Cached content")
    #expect(await gate.calls == 1)
    #expect(try await store.snapshot(accountID: account.id).textSourceBackups?["70"] == "Cached content")
    await richModel.changePageMode(.edit)
    await richModel.sync()
    #expect(await gate.calls == 2)
    #expect(richModel.text == "Cached content")
}

@MainActor
@Test func startupKeepsCachedNoteAfterCredentialFailureAndRetriesOnRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "ClientStartupTests.\(root.lastPathComponent)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = LibraryPreferences(defaults: defaults)
    let store = LocalStore(root: root)
    let account = Account(serverURL: URL(string: "https://retry.invalid")!, userID: "test")
    let page = Page(id: 10, title: "Saved note", fileName: "note.md", filePath: "note.md", collectivePath: nil)
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 7, name: "Saved collective")]
    snapshot.pages["7"] = [page]
    snapshot.documents["10"] = CachedDocument(page: page, collectiveID: 7, markdown: "Saved content", etag: "base")
    try await store.saveAccounts([account])
    try await store.saveSnapshot(snapshot, accountID: account.id)
    var selection = PageLibraryState()
    selection.visit(pageID: page.id, collectiveID: 7)
    preferences.save(selection, accountID: account.id)
    preferences.lastAccountID = account.id
    var attempts = 0
    let model = AppModel(store: store, preferences: preferences, modePreferences: PageModePreferences(defaults: defaults)) { account in
        attempts += 1
        if attempts == 1 { throw CollectivesError.credential(errSecInteractionNotAllowed) }
        return CollectivesClient(account: account, credential: Credential(loginName: "test", appPassword: "test"),
                                 transport: OfflineStartupTransport())
    }
    await model.start()
    #expect(model.startupComplete)
    #expect(model.selectedPage?.id == page.id)
    #expect(model.text == "Saved content")
    #expect(attempts == 1)
    await model.refresh()
    #expect(attempts == 2)
    await model.refresh()
    #expect(attempts == 2)
    #expect(model.text == "Saved content")
    #expect(try await store.snapshot(accountID: account.id).documents["10"]?.markdown == "Saved content")
}
