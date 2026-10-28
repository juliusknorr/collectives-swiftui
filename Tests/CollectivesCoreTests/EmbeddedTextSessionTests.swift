import Foundation
import Testing
@testable import CollectivesCore

@Test func textSessionRejectsStaleAndForeignMessages() {
    var session = EmbeddedTextSession(accountID: UUID(), pageID: 42, markdown: "source")
    let accepted6 = !session.accept(sessionID: UUID(), revision: 1)
    #expect(accepted6)
    let accepted7 = !session.accept(sessionID: session.id, revision: 0)
    #expect(accepted7)
    let accepted8 = session.accept(sessionID: session.id, revision: 2)
    #expect(accepted8)
    let accepted9 = !session.accept(sessionID: session.id, revision: 1)
    #expect(accepted9)
    let accepted10 = !session.accept(sessionID: session.id, revision: 2)
    #expect(accepted10)
    let accepted11 = session.accept(sessionID: session.id, revision: 3)
    #expect(accepted11)
}

@Test func textBackupPreservesFirstSourceAndSurvivesPersistence() throws {
    var snapshot = AccountSnapshot()
    let source = "# 📝 Original\n\n<!-- preserve -->\n\n**Hallo** 日本語\n"
    snapshot.rememberTextSource(pageID: 42, markdown: source)
    snapshot.rememberTextSource(pageID: 42, markdown: "normalized text")
    snapshot.rememberTextSource(pageID: 43, markdown: "other page")
    let restored = try JSONDecoder().decode(AccountSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(restored.textSourceBackups?["42"] == source)
    #expect(restored.textSourceBackups?["43"] == "other page")
}

@Test func existingSnapshotsDecodeWithoutTextBackup() throws {
    let old = Data(#"{"collectives":[],"pages":{},"documents":{}}"#.utf8)
    let snapshot = try JSONDecoder().decode(AccountSnapshot.self, from: old)
    #expect(snapshot.textSourceBackups == nil)
}

@Test func textBackupsSurviveReopeningLocalStoreAfterDocumentChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let page = Page(id: 42, title: "Source backup", fileName: "source.md", filePath: "source.md", collectivePath: nil)
    let source = "# Original 📝\n\n<!-- preserve exact source -->\n\n日本語\n"
    var snapshot = AccountSnapshot()
    snapshot.documents["42"] = CachedDocument(page: page, collectiveID: 7, markdown: source, etag: "base")
    snapshot.rememberTextSource(pageID: page.id, markdown: source)
    let store = LocalStore(root: root)
    try await store.saveSnapshot(snapshot, accountID: accountID)
    snapshot.documents["42"]?.draft = "# Rich-text edit\n"
    try await store.saveSnapshot(snapshot, accountID: accountID)
    let reopened = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(reopened.textSourceBackups?["42"] == source)
    #expect(reopened.documents["42"]?.draft == "# Rich-text edit\n")
}

@Test func legacyTextBackupsSurviveStorageMigrationAndReopening() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let accountID = UUID()
    let source = "# Legacy source\n\n<!-- exact original -->\n"
    var snapshot = AccountSnapshot()
    snapshot.rememberTextSource(pageID: 42, markdown: source)
    try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent(accountID.uuidString + ".json"))
    let migrated = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(migrated.textSourceBackups?["42"] == source)
    let reopened = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(reopened.textSourceBackups?["42"] == source)
}
