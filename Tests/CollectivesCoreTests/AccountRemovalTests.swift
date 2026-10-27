import Foundation
import Testing
@testable import CollectivesCore

private let removalPage = Page(id: 1, title: "Draft", fileName: "Draft.md", filePath: "", collectivePath: "Collectives/Test")

@Test func removingAccountPreservesOtherAccountsAndTheirImages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let account = Account(serverURL: URL(string: "https://cloud.example.test")!, userID: "alice")
    let other = Account(serverURL: account.serverURL, userID: "bob")
    try await store.saveAccounts([account, other])
    var clean = AccountSnapshot()
    clean.documents["1"] = CachedDocument(page: removalPage, collectiveID: 1, markdown: "Saved", etag: "1")
    var pending = clean
    pending.documents["1"]?.draft = "Keep this draft"
    try await store.saveSnapshot(clean, accountID: account.id)
    try await store.saveSnapshot(pending, accountID: other.id)
    let images = ReadingImageCache(root: root.appendingPathComponent("Images"))
    let imageURL = URL(string: "https://cloud.example.test/image.png")!
    try await images.store(Data([1]), for: imageURL, accountID: account.id)
    try await images.store(Data([2]), for: imageURL, accountID: other.id)
    try await store.removeAccount(accountID: account.id) { removed in #expect(removed == account.id) }
    #expect(try await store.accounts() == [other])
    #expect(try await store.snapshot(accountID: account.id).documents.isEmpty)
    #expect(try await store.snapshot(accountID: other.id).documents["1"]?.draft == "Keep this draft")
    #expect(try await images.data(for: imageURL, accountID: account.id) == nil)
    #expect(try await images.data(for: imageURL, accountID: other.id) == Data([2]))
}

@Test(arguments: [false, true]) func removingAccountBlocksDraftsAndConflictOnlyDocuments(conflictOnly: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let account = Account(serverURL: URL(string: "https://cloud.example.test")!, userID: "alice")
    try await store.saveAccounts([account])
    var saved = AccountSnapshot()
    saved.documents["1"] = CachedDocument(page: removalPage, collectiveID: 1, markdown: "Saved", etag: "1",
        draft: conflictOnly ? nil : "Offline changes", conflict: conflictOnly ? RemoteDocument(markdown: "Remote", etag: "2") : nil)
    try await store.saveSnapshot(saved, accountID: account.id)
    await #expect(throws: AccountRemovalError.self) {
        try await store.removeAccount(accountID: account.id) { _ in Issue.record("Credentials must be kept when removal is blocked") }
    }
    #expect(try await store.accounts() == [account])
    let retained = try await store.snapshot(accountID: account.id).documents["1"]
    #expect(retained?.draft == saved.documents["1"]?.draft)
    #expect(retained?.conflict == saved.documents["1"]?.conflict)
}

@Test func credentialRemovalFailureKeepsAccountAndDownloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let account = Account(serverURL: URL(string: "https://cloud.example.test")!, userID: "alice")
    try await store.saveAccounts([account])
    var saved = AccountSnapshot()
    saved.documents["1"] = CachedDocument(page: removalPage, collectiveID: 1, markdown: "Saved", etag: "1")
    try await store.saveSnapshot(saved, accountID: account.id)
    await #expect(throws: CollectivesError.self) {
        try await store.removeAccount(accountID: account.id) { _ in throw CollectivesError.credential(-1) }
    }
    #expect(try await store.accounts() == [account])
    #expect(try await store.snapshot(accountID: account.id).documents["1"]?.markdown == "Saved")
}

@Test func removedAccountRejectsLateDocumentAndSnapshotWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let account = Account(serverURL: URL(string: "https://cloud.example.test")!, userID: "alice")
    try await store.saveAccounts([account])
    var saved = AccountSnapshot()
    let document = CachedDocument(page: removalPage, collectiveID: 1, markdown: "Saved", etag: "1")
    saved.documents["1"] = document
    try await store.saveSnapshot(saved, accountID: account.id)
    try await store.removeAccount(accountID: account.id) { _ in }
    await #expect(throws: CancellationError.self) {
        try await store.saveSnapshot(saved, accountID: account.id)
    }
    await #expect(throws: CancellationError.self) {
        try await store.saveDocument(document, accountID: account.id)
    }
    #expect(try await LocalStore(root: root).snapshot(accountID: account.id).documents.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(account.id.uuidString).path))
}
