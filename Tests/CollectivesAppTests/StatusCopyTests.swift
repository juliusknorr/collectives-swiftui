import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

@MainActor
private func statusModel() -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "StatusCopyTests.\(root.lastPathComponent)")!
    let model = AppModel(store: LocalStore(root: root), preferences: LibraryPreferences(defaults: defaults))
    let account = Account(serverURL: URL(string: "https://status.invalid")!, userID: "alice")
    model.accounts = [account]
    model.activeID = account.id
    return (model, root)
}

private func document(id: Int, draft: String? = nil, conflict: RemoteDocument? = nil) -> CachedDocument {
    let page = Page(id: id, title: "Page \(id)", fileName: "\(id).md", filePath: "", collectivePath: nil)
    return CachedDocument(page: page, collectiveID: 7, markdown: "base", etag: "e", draft: draft, conflict: conflict)
}

@MainActor
@Test func syncSummaryReportsUpToDatePendingDraftsAndLastSync() throws {
    let (model, root) = statusModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    #expect(model.syncSummary(now: now) == "Up to date")
    model.lastSyncDates[model.activeID!] = now.addingTimeInterval(-10)
    #expect(model.syncSummary(now: now) == "Up to date · Synced just now")
    model.lastSyncDates[model.activeID!] = now.addingTimeInterval(-180)
    let summary = model.syncSummary(now: now)
    #expect(summary.hasPrefix("Up to date · Synced "))
    #expect(summary.hasSuffix("ago"))
    model.lastSyncDates = [:]
    model.snapshot.documents["1"] = document(id: 1, draft: "one")
    #expect(model.syncSummary() == "1 draft waiting to sync")
    model.snapshot.documents["2"] = document(id: 2, draft: "two")
    #expect(model.syncSummary() == "2 drafts waiting to sync")
    model.snapshot.documents["3"] = document(id: 3, conflict: RemoteDocument(markdown: "remote", etag: "r"))
    #expect(model.syncSummary() == "1 conflict to review")
}

@MainActor
@Test func pageSaveCaptionOnlyAppearsOutsideTheDefaultState() {
    #expect(PageSaveState.caption(saveFailed: false, document: document(id: 1)) == nil)
    #expect(PageSaveState.caption(saveFailed: false, document: document(id: 1, draft: "x")) == "Draft, not synced")
    #expect(PageSaveState.caption(saveFailed: false, document: document(id: 1, draft: "x",
        conflict: RemoteDocument(markdown: "r", etag: nil))) == "Conflict")
    #expect(PageSaveState.caption(saveFailed: true, document: document(id: 1, draft: "x")) == "Not saved")
}

@MainActor
@Test func transientMessagesClearAfterTheirLifetimeAndOnNavigation() async throws {
    let (model, root) = statusModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.messageLifetime = .milliseconds(1)
    model.message = "Page synced."
    await model.messageClearTask?.value
    #expect(model.message.isEmpty)

    model.messageLifetime = .seconds(60)
    model.message = "Kept the server version."
    model.selectedCollective = 7
    #expect(model.message.isEmpty)
    model.message = "Kept your version. It syncs next."
    model.selectedPage = document(id: 1).page
    #expect(model.message.isEmpty)
}

@MainActor
@Test func repeatingAMessageRestartsItsLifetime() async throws {
    let (model, root) = statusModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.messageLifetime = .milliseconds(1)
    model.message = "Page moved to the server trash."
    let firstTimer = try #require(model.messageClearTask)
    model.messageLifetime = .seconds(60)
    model.message = "Page moved to the server trash."
    await firstTimer.value
    #expect(model.message == "Page moved to the server trash.")
}

@MainActor
@Test func editingDoesNotPostSaveMessages() async throws {
    let (model, root) = statusModel()
    defer { try? FileManager.default.removeItem(at: root) }
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 7, name: "Team")]
    let cached = document(id: 1)
    snapshot.pages["7"] = [cached.page]
    snapshot.documents["1"] = cached
    model.snapshot = snapshot
    model.selectedCollective = 7
    await model.openPage(cached.page)
    await model.changePageMode(.edit)
    model.edited("typed")
    #expect(model.message.isEmpty)
    await model.pendingPersistence?.value
    #expect(model.message.isEmpty)
    #expect(model.document?.draft == "typed")
}

@MainActor
@Test func localGuardsThrowActionableErrors() async throws {
    let (model, root) = statusModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.busy = true
    await #expect(throws: CollectivesError.busy) { try await model.removeAccount(model.activeID!) }
    model.busy = false
    model.persistenceFailed = true
    await #expect(throws: CollectivesError.draftNotSaved) { _ = try await model.accountBackup(model.activeID!) }
    #expect(SyncIssue(error: CollectivesError.signInRequired).requiresSignIn)
}
