import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
private final class LaunchFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let preferences: LibraryPreferences
    let store: LocalStore
    let accounts = [
        Account(serverURL: URL(string: "https://first.invalid")!, userID: "first"),
        Account(serverURL: URL(string: "https://second.invalid")!, userID: "second"),
    ]

    init(launchPage: LaunchPage?, secondLaunchPage: LaunchPage? = nil) async throws {
        defaults = UserDefaults(suiteName: "LaunchPageTests.\(root.lastPathComponent)")!
        preferences = LibraryPreferences(defaults: defaults)
        store = LocalStore(root: root)
        try await store.saveAccounts(accounts)
        var snapshot = AccountSnapshot()
        snapshot.collectives = [Collective(id: 7, name: "Team"), Collective(id: 8, name: "Other")]
        for (collectiveID, pageID) in [(7, 70), (8, 80)] {
            let page = Page(id: pageID, title: "Page \(pageID)", fileName: "\(pageID).md", filePath: "", collectivePath: nil)
            snapshot.pages[String(collectiveID)] = [page]
            snapshot.documents[String(pageID)] = CachedDocument(page: page, collectiveID: collectiveID,
                markdown: "Content \(pageID)", etag: "base")
        }
        for (account, launch) in zip(accounts, [launchPage, secondLaunchPage]) {
            try await store.saveSnapshot(snapshot, accountID: account.id)
            var library = PageLibraryState()
            library.visit(pageID: 70, collectiveID: 7)
            library.launchPage = launch
            preferences.save(library, accountID: account.id)
        }
        preferences.lastAccountID = accounts[0].id
    }

    func startedModel() async -> AppModel {
        let model = AppModel(store: store, preferences: preferences, modePreferences: PageModePreferences(defaults: defaults)) { account in
            CollectivesClient(account: account, credential: Credential(loginName: "test", appPassword: "test"),
                              transport: OfflineTransport())
        }
        await model.start()
        return model
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: "LaunchPageTests.\(root.lastPathComponent)")
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Test func launchOpensLastOpenedPageByDefault() async throws {
    let fixture = try await LaunchFixture(launchPage: nil)
    defer { fixture.cleanup() }
    let model = await fixture.startedModel()
    #expect(model.selectedCollective == 7)
    #expect(model.selectedPage?.id == 70)
}

@MainActor
@Test func launchOpensHomeWhenChosen() async throws {
    let fixture = try await LaunchFixture(launchPage: .home)
    defer { fixture.cleanup() }
    let model = await fixture.startedModel()
    #expect(model.activeID == fixture.accounts[0].id)
    #expect(model.selectedCollective == nil)
    #expect(model.selectedPage == nil)
    #expect(model.launchPage(accountID: fixture.accounts[0].id) == .home)
}

@MainActor
@Test func launchOpensChosenPageInItsCollective() async throws {
    let fixture = try await LaunchFixture(launchPage: .page(80))
    defer { fixture.cleanup() }
    let model = await fixture.startedModel()
    #expect(model.selectedCollective == 8)
    #expect(model.selectedPage?.id == 80)
    #expect(model.text == "Content 80")
}

@MainActor
@Test func launchFallsBackToLastOpenedWhenChosenPageIsGone() async throws {
    let fixture = try await LaunchFixture(launchPage: .page(99))
    defer { fixture.cleanup() }
    let model = await fixture.startedModel()
    #expect(model.selectedCollective == 7)
    #expect(model.selectedPage?.id == 70)
    #expect(model.message == "Your start page is no longer available.")
}

@MainActor
@Test func switchingAccountsIgnoresTheLaunchPage() async throws {
    let fixture = try await LaunchFixture(launchPage: nil, secondLaunchPage: .page(80))
    defer { fixture.cleanup() }
    let model = await fixture.startedModel()
    await model.selectAccount(fixture.accounts[1].id, refresh: false)
    #expect(model.activeID == fixture.accounts[1].id)
    #expect(model.selectedCollective == nil)
    #expect(model.selectedPage == nil)
}

@MainActor
@Test func launchPageToggleAndSettingsPersistPerAccount() async throws {
    let fixture = try await LaunchFixture(launchPage: nil)
    defer { fixture.cleanup() }
    let model = await fixture.startedModel()
    model.toggleLaunchPage(70)
    #expect(fixture.preferences.load(accountID: fixture.accounts[0].id).launchPage == .page(70))
    #expect(model.pageTitle(70, accountID: fixture.accounts[0].id) == "Page 70")
    model.toggleLaunchPage(70)
    #expect(fixture.preferences.load(accountID: fixture.accounts[0].id).launchPage == nil)
    model.setLaunchPage(.home, accountID: fixture.accounts[1].id)
    #expect(fixture.preferences.load(accountID: fixture.accounts[1].id).launchPage == .home)
    #expect(model.launchPage(accountID: fixture.accounts[0].id) == nil)
}
