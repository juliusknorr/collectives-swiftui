import Foundation
import Testing
@testable import CollectivesCore

private actor DownloadStub: AccountSyncAPI {
    enum Failure: Error { case offline }
    let pageList: [Page]
    let failingPage: Int?
    private(set) var requests: [Page] = []

    init(pages: [Page], failingPage: Int? = nil) {
        pageList = pages
        self.failingPage = failingPage
    }

    func collectives() async throws -> [Collective] { [Collective(id: 4, name: "Team")] }
    func pages(collectiveID: Int) async throws -> [Page] { pageList }
    func upload(page: Page, markdown: String, etag: String?) async throws -> String? { Issue.record("Unexpected upload"); return nil }

    func download(page: Page) async throws -> RemoteDocument {
        requests.append(page)
        if page.id == failingPage { throw Failure.offline }
        return RemoteDocument(markdown: "remote \(page.id)", etag: "revision \(page.id)")
    }
}

private actor DownloadCheckpoints {
    private(set) var snapshots: [AccountSnapshot] = []
    func save(_ snapshot: AccountSnapshot) { snapshots.append(snapshot) }
    func latest() -> AccountSnapshot { snapshots.last! }
}

private func downloadPage(_ id: Int, path: String = "Current") -> Page {
    Page(id: id, title: "Page \(id)", fileName: "\(id).md", filePath: path, collectivePath: "Collectives/Team")
}

@Test func offlineDownloadPreservesDraftsAndConflictsWhileRefreshingPaths() async throws {
    var snapshot = AccountSnapshot()
    let conflict = RemoteDocument(markdown: "competing edit", etag: "competing revision")
    snapshot.documents["1"] = CachedDocument(page: downloadPage(1, path: "Old"), collectiveID: 4,
        markdown: "base", etag: "base revision", draft: "local edit")
    snapshot.documents["2"] = CachedDocument(page: downloadPage(2, path: "Old"), collectiveID: 4,
        markdown: "base 2", etag: "base revision 2", conflict: conflict)
    let api = DownloadStub(pages: [downloadPage(1), downloadPage(2)])
    let checkpoints = DownloadCheckpoints()
    let result = try await AccountSynchronizer.download(collectiveID: 4, snapshot: snapshot, api: api) {
        await checkpoints.save($0)
    }.snapshot
    #expect(await api.requests.isEmpty)
    #expect(result.documents["1"]?.draft == "local edit")
    #expect(result.documents["1"]?.markdown == "base")
    #expect(result.documents["1"]?.etag == "base revision")
    #expect(result.documents["2"]?.conflict == conflict)
    #expect(result.documents["2"]?.etag == "base revision 2")
    #expect(result.documents["1"]?.page.filePath == "Current")
    #expect(result.documents["2"]?.page.filePath == "Current")
    let first = await checkpoints.snapshots.first
    #expect(first?.pages["4"] == [downloadPage(1), downloadPage(2)])
    #expect(first?.documents["1"]?.page.filePath == "Current")
    #expect(await checkpoints.snapshots.count == 3)
}

@Test func offlineDownloadRefreshesCleanDocumentsAndKeepsUnlistedCache() async throws {
    var snapshot = AccountSnapshot()
    snapshot.documents["1"] = CachedDocument(page: downloadPage(1, path: "Old"), collectiveID: 4,
        markdown: "old content", etag: "old revision")
    snapshot.documents["99"] = CachedDocument(page: downloadPage(99), collectiveID: 4,
        markdown: "unlisted content", etag: "unlisted revision", draft: "retained draft")
    snapshot.pages["9"] = [downloadPage(90)]
    let api = DownloadStub(pages: [downloadPage(1), downloadPage(2)])
    let result = try await AccountSynchronizer.download(collectiveID: 4, snapshot: snapshot, api: api) { _ in }.snapshot
    #expect(await api.requests.map(\.id).sorted() == [1, 2])
    #expect(result.documents["1"]?.markdown == "remote 1")
    #expect(result.documents["1"]?.etag == "revision 1")
    #expect(result.documents["1"]?.page.filePath == "Current")
    #expect(result.documents["2"]?.markdown == "remote 2")
    #expect(result.documents["99"]?.draft == "retained draft")
    #expect(result.pages["9"] == snapshot.pages["9"])
}

@Test func offlineDownloadReportsFailedPagesAndCanRetry() async throws {
    let pages = [downloadPage(1), downloadPage(2), downloadPage(3)]
    let api = DownloadStub(pages: pages, failingPage: 2)
    var snapshot = AccountSnapshot()
    snapshot.documents["2"] = CachedDocument(page: downloadPage(2, path: "Old"), collectiveID: 4,
        markdown: "previously cached", etag: "previous revision")
    let partial = try await AccountSynchronizer.download(collectiveID: 4, snapshot: snapshot, api: api) { _ in }
    #expect(partial.failures.map(\.pageID) == [2])
    #expect(partial.snapshot.pages["4"] == pages)
    #expect(partial.snapshot.documents["1"]?.markdown == "remote 1")
    #expect(partial.snapshot.documents["2"]?.markdown == "previously cached")
    #expect(partial.snapshot.documents["2"]?.etag == "previous revision")
    #expect(partial.snapshot.documents["2"]?.page.filePath == "Current")
    #expect(partial.snapshot.documents["3"]?.markdown == "remote 3")
    let retryAPI = DownloadStub(pages: pages)
    let recovered = try await AccountSynchronizer.download(collectiveID: 4, snapshot: partial.snapshot, api: retryAPI) { _ in }
    #expect(recovered.failures.isEmpty)
    #expect(recovered.snapshot.documents["2"]?.markdown == "remote 2")
}

@Test func offlineDownloadStopsWhenCheckpointCannotBeSaved() async throws {
    let api = DownloadStub(pages: [downloadPage(1)])
    await #expect(throws: DownloadStub.Failure.self) {
        try await AccountSynchronizer.download(collectiveID: 4, snapshot: AccountSnapshot(), api: api) { _ in
            throw DownloadStub.Failure.offline
        }
    }
    #expect(await api.requests.isEmpty)
}

@Test func offlineDownloadHonorsCancellationBeforeAdmittingMorePages() async throws {
    let api = DownloadStub(pages: (1...5).map { downloadPage($0) })
    let checkpoints = DownloadCheckpoints()
    let task = Task {
        try await AccountSynchronizer.download(collectiveID: 4, snapshot: AccountSnapshot(), api: api) {
            await checkpoints.save($0)
            if !$0.documents.isEmpty {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await api.requests.count <= 3)
    #expect(await api.requests.allSatisfy { (1...3).contains($0.id) })
    let partial = await checkpoints.latest()
    #expect(partial.documents.count == 1)
    let saved = try #require(partial.documents.values.first)
    #expect(saved.markdown == "remote \(saved.page.id)")
    #expect(await checkpoints.snapshots.count == 2)
}
