import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private func sidebarSnapshot(_ name: String, markdown: String) -> AccountSnapshot {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 7, name: name)]
    let page = Page(id: 10, title: name, fileName: "page.md", filePath: "page.md", collectivePath: nil)
    snapshot.pages["7"] = [page]
    snapshot.documents["10"] = CachedDocument(page: page, collectiveID: 7, markdown: markdown, etag: "revision")
    return snapshot
}

@MainActor
@Test func sidebarSwitchesAccountsWithMatchingCollectiveAndPageIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "AccountSidebarTests.\(root.lastPathComponent)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LocalStore(root: root)
    let first = Account(serverURL: URL(string: "https://first.invalid")!, userID: "first")
    let second = Account(serverURL: URL(string: "https://second.invalid")!, userID: "second")
    let firstSnapshot = sidebarSnapshot("First collective", markdown: "First account text")
    let secondSnapshot = sidebarSnapshot("Second collective", markdown: "Second account text")
    try await store.saveSnapshot(firstSnapshot, accountID: first.id)
    try await store.saveSnapshot(secondSnapshot, accountID: second.id)
    let model = AppModel(store: store, preferences: LibraryPreferences(defaults: defaults))
    model.accounts = [first, second]
    model.activeID = first.id
    model.snapshot = firstSnapshot
    model.accountCollectives[second.id] = secondSnapshot.collectives
    model.selectedCollective = 7
    await model.openPage(firstSnapshot.pages["7"]![0])
    model.edited("Unsynced first account draft")

    #expect(await model.openSidebar(accountID: second.id, collectiveID: 7))
    #expect(model.activeID == second.id)
    #expect(model.selectedCollective == 7)
    #expect(model.selectedPage == nil)
    #expect(model.text.isEmpty)
    await model.openPage(secondSnapshot.pages["7"]![0])
    #expect(model.text == "Second account text")
    #expect(model.collectives(for: first.id).map(\.name) == ["First collective"])
    #expect(model.collectives(for: second.id).map(\.name) == ["Second collective"])
    let savedFirst = try await store.snapshot(accountID: first.id)
    let savedSecond = try await store.snapshot(accountID: second.id)
    #expect(savedFirst.documents["10"]?.draft == "Unsynced first account draft")
    #expect(savedSecond.documents["10"]?.draft == nil)

    #expect(await model.openSidebar(accountID: first.id, collectiveID: nil))
    #expect(model.activeID == first.id)
    #expect(model.selectedCollective == nil)
    #expect(model.selectedPage == nil)
    #expect(model.text.isEmpty)
    await model.openPage(firstSnapshot.pages["7"]![0])
    #expect(model.text == "Unsynced first account draft")
}

@MainActor
@Test func sidebarKeepsSelectionWhenDraftCannotBeSaved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "AccountSidebarTests.\(root.lastPathComponent)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = Account(serverURL: URL(string: "https://first.invalid")!, userID: "first")
    let second = Account(serverURL: URL(string: "https://second.invalid")!, userID: "second")
    let model = AppModel(store: LocalStore(root: root), preferences: LibraryPreferences(defaults: defaults))
    model.accounts = [first, second]
    model.activeID = first.id
    model.snapshot = sidebarSnapshot("First collective", markdown: "Saved text")
    model.selectedCollective = 7
    let page = model.snapshot.pages["7"]![0]
    await model.openPage(page)
    model.edited("Draft that could not be saved")

    #expect(await !model.openSidebar(accountID: second.id, collectiveID: 7))
    #expect(model.activeID == first.id)
    #expect(model.selectedCollective == 7)
    #expect(model.selectedPage == page)
    #expect(model.text == "Draft that could not be saved")
    #expect(model.snapshot.documents["10"]?.draft == "Draft that could not be saved")
    #expect(await !model.openSidebar(accountID: first.id, collectiveID: nil))
    #expect(model.selectedPage == page)
}

@MainActor
@Test func sidebarLoadsAllCachedAccountsWhenRefreshIsUnavailable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "AccountSidebarTests.\(root.lastPathComponent)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LocalStore(root: root)
    let first = Account(serverURL: URL(string: "https://first.invalid")!, userID: "first")
    let second = Account(serverURL: URL(string: "https://second.invalid")!, userID: "second")
    try await store.saveAccounts([first, second])
    try await store.saveSnapshot(sidebarSnapshot("First collective", markdown: "First text"), accountID: first.id)
    try await store.saveSnapshot(sidebarSnapshot("Second collective", markdown: "Second text"), accountID: second.id)
    let preferences = LibraryPreferences(defaults: defaults)
    preferences.lastAccountID = second.id
    let model = AppModel(store: store, preferences: preferences)

    await model.start()
    #expect(model.accounts == [first, second])
    #expect(model.activeID == second.id)
    #expect(model.collectives(for: first.id).map(\.name) == ["First collective"])
    #expect(model.collectives(for: second.id).map(\.name) == ["Second collective"])
    #expect(model.collectiveListingErrors[first.id] != nil)
    #expect(model.collectiveListingErrors[second.id] != nil)
    await model.refresh()
    #expect(model.activeID == second.id)
    #expect(model.snapshot.documents["10"]?.markdown == "Second text")
    let savedFirst = try await store.snapshot(accountID: first.id)
    #expect(savedFirst.documents["10"]?.markdown == "First text")
}

@MainActor
@Test func sidebarRejectsUnknownAccountsAndCollectives() async {
    let account = Account(serverURL: URL(string: "https://example.invalid")!, userID: "user")
    let model = AppModel()
    model.accounts = [account]
    model.activeID = account.id
    model.snapshot = sidebarSnapshot("Collective", markdown: "Saved text")
    model.selectedCollective = 7
    #expect(await !model.openSidebar(accountID: UUID(), collectiveID: 7))
    #expect(await !model.openSidebar(accountID: account.id, collectiveID: 99))
    #expect(model.activeID == account.id)
    #expect(model.selectedCollective == 7)
}
