import Foundation
import Testing
@testable import CollectivesCore

private func parallelPage(_ id: Int) -> Page {
    Page(id: id, title: "Page \(id)", fileName: "\(id).md", filePath: "", collectivePath: "Collectives/Team")
}

/// Holds network operations and the first document checkpoint independently.
private actor ParallelSyncGate: AccountSyncAPI {
    enum Failure: Error { case unavailable, checkpoint }
    let pageIDs: [Int]
    let failingPages: Set<Int>
    let failCheckpoint: Bool
    private(set) var started: [Int] = []
    private(set) var cancelled: Set<Int> = []
    private(set) var maximumActive = 0
    private(set) var metadataRequests = 0
    private(set) var snapshots: [AccountSnapshot] = []
    private(set) var checkpointProgress: [AccountSyncProgress?] = []
    private(set) var progress: [AccountSyncProgress] = []
    private var active = 0
    private var requests: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var released: Set<Int> = []
    private var releaseAllRequests = false
    private var checkpointHeld = false
    private var checkpointReleased = false
    private var checkpointWaiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    init(pageIDs: [Int] = Array(1...6), failingPages: Set<Int> = [], failCheckpoint: Bool = false) {
        self.pageIDs = pageIDs
        self.failingPages = failingPages
        self.failCheckpoint = failCheckpoint
    }

    func collectives() async throws -> [Collective] {
        metadataRequests += 1
        return [Collective(id: 1, name: "Team")]
    }

    func pages(collectiveID: Int) async throws -> [Page] {
        metadataRequests += 1
        return pageIDs.map(parallelPage)
    }

    func download(page: Page) async throws -> RemoteDocument {
        try await request(page.id)
        return RemoteDocument(markdown: "remote \(page.id)", etag: "\"remote\"")
    }

    func upload(page: Page, markdown: String, etag: String?) async throws -> String? {
        try await request(page.id)
        return "\"saved\""
    }

    private func request(_ id: Int) async throws {
        try Task.checkCancellation()
        started.append(id)
        active += 1
        maximumActive = max(maximumActive, active)
        changed()
        defer { active -= 1 }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cancelled.insert(id)
                    continuation.resume(throwing: CancellationError())
                } else if releaseAllRequests || released.contains(id) {
                    continuation.resume()
                } else {
                    requests[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
        if failingPages.contains(id) { throw Failure.unavailable }
    }

    private func cancel(_ id: Int) {
        cancelled.insert(id)
        requests.removeValue(forKey: id)?.resume(throwing: CancellationError())
        changed()
    }

    func release(_ id: Int) {
        released.insert(id)
        requests.removeValue(forKey: id)?.resume()
    }

    func releaseEverything() {
        releaseAllRequests = true
        let pending = Array(requests.values)
        requests.removeAll()
        for continuation in pending { continuation.resume() }
        releaseCheckpoint()
    }

    func record(_ event: AccountSyncProgress) { progress.append(event) }

    func checkpoint(_ snapshot: AccountSnapshot) async throws {
        guard !snapshot.documents.isEmpty else { return }
        snapshots.append(snapshot)
        checkpointProgress.append(progress.last)
        if !checkpointHeld {
            checkpointHeld = true
            changed()
            if !checkpointReleased {
                await withCheckedContinuation { checkpointWaiter = $0 }
            }
            if failCheckpoint { throw Failure.checkpoint }
        }
    }

    func releaseCheckpoint() {
        checkpointReleased = true
        checkpointWaiter?.resume()
        checkpointWaiter = nil
    }

    func waitForStarts(_ count: Int) async {
        while started.count < count { await nextChange() }
    }

    func waitForCheckpoint() async {
        while !checkpointHeld { await nextChange() }
    }

    private func nextChange() async {
        await withCheckedContinuation { observers.append($0) }
    }

    private func changed() {
        let pending = observers
        observers.removeAll()
        for observer in pending { observer.resume() }
    }
}

@Test(.timeLimit(.minutes(1))) func parallelSyncAdmitsOnlyThreeAndWaitsForCheckpointBeforeReplacement() async throws {
    let gate = ParallelSyncGate()
    let task = Task {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: gate,
            progress: { await gate.record($0) }, checkpoint: { try await gate.checkpoint($0) })
    }
    await gate.waitForStarts(3)
    #expect(Set(await gate.started) == [1, 2, 3])
    await gate.release(2)
    await gate.waitForCheckpoint()
    #expect(await gate.started.count == 3)
    #expect(await gate.checkpointProgress.compactMap { $0?.completedPages }.first == 0)
    await gate.releaseCheckpoint()
    await gate.waitForStarts(4)
    #expect(await gate.started.last == 4)
    await gate.releaseEverything()
    let result = try await task.value
    #expect(result.snapshot.documents.count == 6)
    #expect(await gate.maximumActive == 3)
}

@Test(.timeLimit(.minutes(1))) func parallelSyncMergesOutOfOrderResultsWithoutLosingDocuments() async throws {
    let gate = ParallelSyncGate(pageIDs: [1, 2, 3])
    let task = Task {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: gate,
            progress: { await gate.record($0) }, checkpoint: { try await gate.checkpoint($0) })
    }
    await gate.waitForStarts(3)
    await gate.release(3)
    await gate.waitForCheckpoint()
    #expect(await gate.snapshots.first?.documents.keys.sorted() == ["3"])
    await gate.releaseEverything()
    let result = try await task.value
    #expect(Set(result.snapshot.documents.keys) == ["1", "2", "3"])
    let saved = await gate.snapshots
    #expect(saved.map { $0.documents.count } == [1, 2, 3])
    #expect(await gate.checkpointProgress.compactMap { $0?.completedPages } == [0, 1, 2])
    #expect(await gate.progress.last?.completedPages == 3)
    #expect(await gate.progress.last?.phase == .finished)
}

@Test(.timeLimit(.minutes(1))) func parallelSyncRetainsSuccessfulPagesWhenAnotherRequestFails() async throws {
    let gate = ParallelSyncGate(pageIDs: [1, 2, 3, 4], failingPages: [2])
    let task = Task {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: gate,
            checkpoint: { try await gate.checkpoint($0) })
    }
    await gate.waitForStarts(3)
    await gate.releaseEverything()
    let result = try await task.value
    #expect(Set(result.snapshot.documents.keys) == ["1", "3", "4"])
    #expect(result.failures.map(\.pageID) == [2])
    #expect(Set(await gate.started) == [1, 2, 3, 4])
}

@Test(.timeLimit(.minutes(1))) func parallelSyncCancelsInflightRequestsAndDoesNotAdmitMore() async throws {
    let gate = ParallelSyncGate()
    let task = Task {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: gate,
            checkpoint: { try await gate.checkpoint($0) })
    }
    await gate.waitForStarts(3)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Set(await gate.started) == [1, 2, 3])
    #expect(await gate.cancelled == [1, 2, 3])
    #expect(await gate.snapshots.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func parallelSyncCheckpointFailureCancelsInflightRequestsAndStopsAdmission() async throws {
    let gate = ParallelSyncGate(failCheckpoint: true)
    let task = Task {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: gate,
            progress: { await gate.record($0) }, checkpoint: { try await gate.checkpoint($0) })
    }
    await gate.waitForStarts(3)
    await gate.release(1)
    await gate.waitForCheckpoint()
    await gate.releaseCheckpoint()
    await #expect(throws: ParallelSyncGate.Failure.self) { try await task.value }
    #expect(Set(await gate.started) == [1, 2, 3])
    #expect(await gate.cancelled == [2, 3])
    #expect(await gate.progress.allSatisfy { $0.completedPages == 0 && $0.phase != .finished })
}

@Test(.timeLimit(.minutes(1))) func parallelSyncDeduplicatesPageIDsBeforeStartingRequests() async throws {
    let gate = ParallelSyncGate(pageIDs: [1, 1, 2, 3, 4, 2])
    let task = Task {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: gate,
            progress: { await gate.record($0) }, checkpoint: { try await gate.checkpoint($0) })
    }
    await gate.waitForStarts(3)
    #expect(Set(await gate.started) == [1, 2, 3])
    await gate.releaseEverything()
    let result = try await task.value
    #expect(await gate.started.count == 4)
    #expect(result.snapshot.documents.count == 4)
    #expect(await gate.progress.last?.completedPages == 4)
    #expect(await gate.progress.last?.totalPages == 4)
}

@Test(.timeLimit(.minutes(1))) func parallelDraftSyncUsesThreeRequestsWithoutListingOrPruning() async throws {
    let gate = ParallelSyncGate()
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 1, name: "Team")]
    snapshot.pages["1"] = (1...6).map(parallelPage)
    for id in 1...6 {
        snapshot.documents[String(id)] = CachedDocument(page: parallelPage(id), collectiveID: 1,
            markdown: "base", etag: "\"base\"", draft: "edit \(id)")
    }
    let input = snapshot
    let task = Task {
        try await AccountSynchronizer.synchronizeDrafts(snapshot: input, api: gate,
            progress: { await gate.record($0) }, checkpoint: { try await gate.checkpoint($0) })
    }
    await gate.waitForStarts(3)
    #expect(await gate.metadataRequests == 0)
    await gate.releaseEverything()
    let result = try await task.value
    #expect(await gate.maximumActive == 3)
    #expect(await gate.started.count == 6)
    #expect(await gate.metadataRequests == 0)
    #expect(result.snapshot.collectives == input.collectives)
    #expect(result.snapshot.pages == input.pages)
    #expect(result.snapshot.documents.values.allSatisfy { $0.draft == nil })
}
