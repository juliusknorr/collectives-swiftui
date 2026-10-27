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
