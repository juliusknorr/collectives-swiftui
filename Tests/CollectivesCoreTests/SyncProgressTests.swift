import Foundation
import Testing
@testable import CollectivesCore

private func progressPage(_ id: Int) -> Page {
    Page(id: id, title: "Page \(id)", fileName: "\(id).md", filePath: "", collectivePath: "Collectives/Team")
}

private actor ProgressAPI: AccountSyncAPI {
    enum Failure: Error { case unavailable }
    let groups: [Collective]
    let listings: [Int: [Page]]
    let failingGroups: Set<Int>
    let failingPages: Set<Int>
    let cancelDownload: Bool

    init(groups: [Collective] = [Collective(id: 1, name: "Team")],
         listings: [Int: [Page]] = [:], failingGroups: Set<Int> = [],
         failingPages: Set<Int> = [], cancelDownload: Bool = false) {
        self.groups = groups
        self.listings = listings
        self.failingGroups = failingGroups
        self.failingPages = failingPages
        self.cancelDownload = cancelDownload
    }

    func collectives() async throws -> [Collective] { groups }
    func pages(collectiveID: Int) async throws -> [Page] {
        if failingGroups.contains(collectiveID) { throw Failure.unavailable }
        return listings[collectiveID] ?? []
    }
    func download(page: Page) async throws -> RemoteDocument {
        if cancelDownload { throw CancellationError() }
        if failingPages.contains(page.id) { throw Failure.unavailable }
        return RemoteDocument(markdown: "remote \(page.id)", etag: "\"remote\"")
    }
    func upload(page: Page, markdown: String, etag: String?) async throws -> String? { "\"saved\"" }
}

private actor ProgressRecorder {
    private(set) var events: [AccountSyncProgress] = []
    private(set) var checkpointEvents: [AccountSyncProgress?] = []
    let failCheckpoint: Int?
    let cancelCheckpoint: Int?

    init(failCheckpoint: Int? = nil, cancelCheckpoint: Int? = nil) {
        self.failCheckpoint = failCheckpoint
        self.cancelCheckpoint = cancelCheckpoint
    }
    func record(_ event: AccountSyncProgress) { events.append(event) }
    func checkpoint(_ snapshot: AccountSnapshot) throws {
        checkpointEvents.append(events.last)
        if checkpointEvents.count == failCheckpoint { throw ProgressAPI.Failure.unavailable }
        if checkpointEvents.count == cancelCheckpoint { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

@Test func syncProgressReportsPageOperationsAndDurableCompletion() async throws {
    let group = Collective(id: 1, name: "Team")
    var snapshot = AccountSnapshot()
    snapshot.documents["1"] = CachedDocument(page: progressPage(1), collectiveID: 1,
        markdown: "base", etag: "\"base\"", draft: "edit")
    snapshot.documents["3"] = CachedDocument(page: progressPage(3), collectiveID: 1,
        markdown: "cached", etag: "\"base\"")
    let api = ProgressAPI(groups: [group], listings: [1: (1...3).map(progressPage)])
    let recorder = ProgressRecorder()
    _ = try await AccountSynchronizer.synchronize(snapshot: snapshot, api: api,
        progress: { await recorder.record($0) }, checkpoint: { try await recorder.checkpoint($0) })

    let events = await recorder.events
    #expect(events.first?.phase == .listingCollectives)
    #expect(events.first?.totalCollectives == nil)
    let listing = try #require(events.first { $0.phase == .listingPages })
    #expect(listing.collective == group)
    #expect(listing.totalCollectives == 1)
    #expect(listing.totalPages == nil)
    let operations = events.filter { [.uploading, .downloading, .checking].contains($0.phase) }
    #expect(operations.map(\.phase) == [.uploading, .downloading, .checking])
    #expect(operations.map { $0.page?.id } == [1, 2, 3])
    #expect(operations.map(\.completedPages) == [0, 1, 2])
    #expect(operations.allSatisfy { $0.totalPages == 3 })
    let pageCheckpoints = await recorder.checkpointEvents.compactMap { $0 }.filter { $0.page != nil }
    #expect(pageCheckpoints.map(\.phase) == [.saving, .saving, .saving])
    #expect(pageCheckpoints.map(\.completedPages) == [0, 1, 2])
    #expect(events.last?.phase == .finished)
    #expect(events.last?.completedCollectives == 1)
    #expect(events.last?.failureCount == 0)
}

@Test func syncProgressCountsPageAndMetadataFailuresWhileContinuing() async throws {
    let groups = (1...3).map { Collective(id: $0, name: "Team \($0)") }
    let api = ProgressAPI(groups: groups,
        listings: [1: [progressPage(1), progressPage(2)], 3: [progressPage(3)]],
        failingGroups: [2], failingPages: [1])
    let recorder = ProgressRecorder()
    let result = try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: api,
        progress: { await recorder.record($0) }, checkpoint: { try await recorder.checkpoint($0) })

    let events = await recorder.events
    #expect(result.failures.count == 2)
    let thirdListing = try #require(events.first { $0.phase == .listingPages && $0.collective?.id == 3 })
    #expect(thirdListing.completedCollectives == 2)
    #expect(thirdListing.failureCount == 2)
    let secondPage = try #require(events.first { $0.phase == .downloading && $0.page?.id == 2 })
    #expect(secondPage.completedPages == 1)
    #expect(secondPage.failureCount == 1)
    #expect(events.last?.phase == .finished)
    #expect(events.last?.completedCollectives == 3)
    #expect(events.last?.totalCollectives == 3)
    #expect(events.last?.failureCount == result.failures.count)
}

@Test func syncProgressFinishesEmptyAccountsAndCollectives() async throws {
    let emptyAccount = ProgressRecorder()
    _ = try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: ProgressAPI(groups: []),
        progress: { await emptyAccount.record($0) }, checkpoint: { try await emptyAccount.checkpoint($0) })
    #expect(await emptyAccount.events.first?.phase == .listingCollectives)
    #expect(await emptyAccount.events.last?.phase == .finished)
    #expect(await emptyAccount.events.last?.totalCollectives == 0)
    #expect(await emptyAccount.events.last?.completedCollectives == 0)

    let emptyCollective = ProgressRecorder()
    _ = try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: ProgressAPI(),
        progress: { await emptyCollective.record($0) }, checkpoint: { try await emptyCollective.checkpoint($0) })
    #expect(await emptyCollective.events.last?.phase == .finished)
    #expect(await emptyCollective.events.last?.completedCollectives == 1)
    #expect(await emptyCollective.events.allSatisfy { $0.page == nil })
}

@Test func downloadProgressStartsAtPageListingAndPreservesDrafts() async throws {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 1, name: "Team")]
    snapshot.documents["1"] = CachedDocument(page: progressPage(1), collectiveID: 1,
        markdown: "base", etag: "\"base\"", draft: "edit")
    let recorder = ProgressRecorder()
    let result = try await AccountSynchronizer.download(collectiveID: 1, snapshot: snapshot,
        api: ProgressAPI(listings: [1: [progressPage(1), progressPage(2)]]),
        progress: { await recorder.record($0) }, checkpoint: { try await recorder.checkpoint($0) })
    let events = await recorder.events
    #expect(events.first?.phase == .listingPages)
    #expect(events.first?.collective?.id == 1)
    #expect(events.first?.totalPages == nil)
    #expect(!events.contains { $0.phase == .uploading })
    #expect(events.contains { $0.phase == .downloading && $0.page?.id == 2 })
    #expect(result.snapshot.documents["1"]?.draft == "edit")
    #expect(events.last?.phase == .finished)
    #expect(events.last?.completedCollectives == 1)
}

@Test func syncProgressDoesNotClaimCompletionWhenPageCheckpointFails() async throws {
    let recorder = ProgressRecorder(failCheckpoint: 3)
    await #expect(throws: ProgressAPI.Failure.self) {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(),
            api: ProgressAPI(listings: [1: [progressPage(1), progressPage(2)]]),
            progress: { await recorder.record($0) }, checkpoint: { try await recorder.checkpoint($0) })
    }
    let events = await recorder.events
    #expect(events.last?.phase == .saving)
    #expect(events.last?.page?.id == 1)
    #expect(events.last?.completedPages == 0)
    #expect(events.last?.completedCollectives == 0)
    #expect(!events.contains { $0.phase == .finished })
    #expect(!events.contains { $0.page?.id == 2 })
}

@Test func syncProgressDoesNotClaimCompletionAfterCancellation() async throws {
    let recorder = ProgressRecorder()
    await #expect(throws: CancellationError.self) {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(),
            api: ProgressAPI(listings: [1: [progressPage(1)]], cancelDownload: true),
            progress: { await recorder.record($0) }, checkpoint: { try await recorder.checkpoint($0) })
    }
    let events = await recorder.events
    #expect(events.last?.phase == .downloading)
    #expect(events.last?.completedPages == 0)
    #expect(events.last?.completedCollectives == 0)
    #expect(events.last?.failureCount == 0)
    #expect(!events.contains { $0.phase == .finished })
}

@Test func syncProgressDoesNotFinishWhenCancelledDuringFinalCheckpoint() async throws {
    let recorder = ProgressRecorder(cancelCheckpoint: 3)
    let task = Task {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(),
            api: ProgressAPI(listings: [1: [progressPage(1)]]),
            progress: { await recorder.record($0) }, checkpoint: { try await recorder.checkpoint($0) })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await recorder.events.last?.completedCollectives == 0)
    #expect(await recorder.events.allSatisfy { $0.phase != .finished })
}
