import Foundation
import Testing
@testable import CollectivesCore

private actor DocumentStub: DocumentAPI {
    enum Failure: Error { case offline }
    var remote: RemoteDocument
    let uploadError: (any Error)?
    let downloadError: (any Error)?
    let uploadRevision: String?
    private(set) var downloads = 0
    private(set) var uploads: [(markdown: String, etag: String?)] = []

    init(remote: RemoteDocument = RemoteDocument(markdown: "base", etag: "\"base\""),
         uploadRevision: String? = "\"saved\"", uploadError: (any Error)? = nil,
         downloadError: (any Error)? = nil) {
        self.remote = remote
        self.uploadRevision = uploadRevision
        self.uploadError = uploadError
        self.downloadError = downloadError
    }
    func download(page: Page) async throws -> RemoteDocument {
        downloads += 1
        if let downloadError { throw downloadError }
        return remote
    }
    func upload(page: Page, markdown: String, etag: String?) async throws -> String? {
        uploads.append((markdown, etag))
        if let uploadError { throw uploadError }
        return uploadRevision
    }
}

private func syncDocument(etag: String? = "\"base\"", draft: String? = "local edit") -> CachedDocument {
    CachedDocument(page: Page(id: 42, title: "Notes", fileName: "Notes.md", filePath: "", collectivePath: "Collectives/Team"),
                   collectiveID: 1, markdown: "base", etag: etag, draft: draft)
}

@Test func synchronizerUploadsDraftConditionally() async throws {
    let api = DocumentStub()
    let updated = try await DocumentSynchronizer.synchronize(document: syncDocument(), api: api)
    #expect(updated.markdown == "local edit")
    #expect(updated.draft == nil)
    #expect(updated.etag == "\"saved\"")
    #expect(await api.downloads == 0)
    let uploads = await api.uploads
    #expect(uploads.count == 1)
    #expect(uploads.first?.etag == "\"base\"")
    #expect(uploads.first?.markdown == "local edit")
}

@Test func synchronizerRefreshesCleanPage() async throws {
    let api = DocumentStub(remote: RemoteDocument(markdown: "server edit", etag: "\"new\""))
    let updated = try await DocumentSynchronizer.synchronize(document: syncDocument(draft: nil), api: api)
    #expect(updated.markdown == "server edit")
    #expect(updated.etag == "\"new\"")
    #expect(updated.draft == nil)
    #expect(await api.uploads.isEmpty)
}

@Test func failedSyncLeavesPersistedDraftAndRevisionIntact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let accountID = UUID()
    var snapshot = AccountSnapshot()
    snapshot.documents["42"] = syncDocument()
    try await store.saveSnapshot(snapshot, accountID: accountID)
    let api = DocumentStub(uploadError: DocumentStub.Failure.offline)
    await #expect(throws: DocumentStub.Failure.self) {
        try await DocumentSynchronizer.synchronize(document: snapshot.documents["42"]!, api: api)
    }
    let restarted = LocalStore(root: root)
    let restored = try await restarted.snapshot(accountID: accountID).documents["42"]
    #expect(restored?.draft == "local edit")
    #expect(restored?.markdown == "base")
    #expect(restored?.etag == "\"base\"")
}

@Test(arguments: [CollectivesError.conflict, CollectivesError.http(412)])
func conflictPreservesDraftAndStopsRepeatedRequests(error: CollectivesError) async throws {
    let remote = RemoteDocument(markdown: "competing edit", etag: "\"remote\"")
    let api = DocumentStub(remote: remote, uploadError: error)
    var updated = try await DocumentSynchronizer.synchronize(document: syncDocument(), api: api)
    #expect(updated.conflict == remote)
    #expect(updated.markdown == "base")
    #expect(updated.draft == "local edit")
    #expect(updated.etag == "\"base\"")
    updated.draft = "more local edits while resolving"
    let repeated = try await DocumentSynchronizer.synchronize(document: updated, api: api)
    #expect(repeated.draft == "more local edits while resolving")
    #expect(repeated.conflict == remote)
    #expect(await api.downloads == 1)
    #expect(await api.uploads.count == 1)
}

@Test func missingRevisionChecksRemoteBeforeUploading() async throws {
    let api = DocumentStub()
    let updated = try await DocumentSynchronizer.synchronize(document: syncDocument(etag: nil), api: api)
    #expect(updated.draft == nil)
    #expect(await api.downloads == 1)
    #expect(await api.uploads.first?.etag == "\"base\"")
}

@Test func missingRevisionDetectsConflictWithoutUploading() async throws {
    let remote = RemoteDocument(markdown: "competing edit", etag: "\"new\"")
    let api = DocumentStub(remote: remote)
    let updated = try await DocumentSynchronizer.synchronize(document: syncDocument(etag: nil), api: api)
    #expect(updated.conflict == remote)
    #expect(updated.draft == "local edit")
    #expect(await api.uploads.isEmpty)
}

@Test(arguments: [nil, "", "W/\"weak\""] as [String?])
func unusableRemoteRevisionCannotOverwritePage(revision: String?) async throws {
    let api = DocumentStub(remote: RemoteDocument(markdown: "base", etag: revision))
    await #expect(throws: CollectivesError.self) {
        try await DocumentSynchronizer.synchronize(document: syncDocument(etag: nil), api: api)
    }
    #expect(await api.uploads.isEmpty)
}

@Test func uploadWithoutRevisionDoesNotReuseStaleBase() async throws {
    let api = DocumentStub(uploadRevision: nil)
    var updated = try await DocumentSynchronizer.synchronize(document: syncDocument(), api: api)
    #expect(updated.markdown == "local edit")
    #expect(updated.draft == nil)
    #expect(updated.etag == nil)

    updated.draft = "second local edit"
    let nextAPI = DocumentStub(remote: RemoteDocument(markdown: "new competing edit", etag: "\"other\""))
    let conflicted = try await DocumentSynchronizer.synchronize(document: updated, api: nextAPI)
    #expect(conflicted.draft == "second local edit")
    #expect(conflicted.conflict?.markdown == "new competing edit")
    #expect(await nextAPI.uploads.isEmpty)
}

@Test func conflictFetchFailurePreservesOriginalDraftForRetry() async throws {
    let original = syncDocument()
    let api = DocumentStub(uploadError: CollectivesError.conflict, downloadError: DocumentStub.Failure.offline)
    await #expect(throws: DocumentStub.Failure.self) {
        try await DocumentSynchronizer.synchronize(document: original, api: api)
    }
    #expect(original.draft == "local edit")
    #expect(original.markdown == "base")
    #expect(original.conflict == nil)
}

@Test func retryAfterLostUploadResponseRecognizesSavedDraft() async throws {
    let api = DocumentStub(remote: RemoteDocument(markdown: "local edit", etag: "\"saved\""),
                           uploadError: CollectivesError.conflict)
    let updated = try await DocumentSynchronizer.synchronize(document: syncDocument(), api: api)
    #expect(updated.markdown == "local edit")
    #expect(updated.draft == nil)
    #expect(updated.conflict == nil)
    #expect(updated.etag == "\"saved\"")
}
