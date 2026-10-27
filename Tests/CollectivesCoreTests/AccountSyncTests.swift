import Foundation
import Testing
@testable import CollectivesCore

private func accountSyncPage(_ id: Int, title: String = "Page") -> Page {
    Page(id: id, title: title, fileName: "\(id).md", filePath: "", collectivePath: "Collectives/Team")
}

private actor AccountSyncStub: AccountSyncAPI {
    enum Failure: Error { case unavailable }
    let groups: [Collective]
    let listings: [Int: [Page]]
    let failingPages: Set<Int>
    let failingGroups: Set<Int>
    let unchangedPages: Set<Int>
    private(set) var downloads: [(Int, String?)] = []
    private(set) var uploads: [(Int, String?)] = []
    private(set) var requestedGroups: [Int] = []

    init(groups: [Collective] = [Collective(id: 1, name: "Team")], listings: [Int: [Page]],
         failingPages: Set<Int> = [], failingGroups: Set<Int> = [], unchangedPages: Set<Int> = []) {
        self.groups = groups; self.listings = listings; self.failingPages = failingPages
        self.failingGroups = failingGroups; self.unchangedPages = unchangedPages
    }
    func collectives() async throws -> [Collective] { groups }
    func pages(collectiveID: Int) async throws -> [Page] {
        requestedGroups.append(collectiveID)
        if failingGroups.contains(collectiveID) { throw Failure.unavailable }
        return listings[collectiveID] ?? []
    }
    func download(page: Page) async throws -> RemoteDocument {
        try await download(page: page, ifNoneMatch: nil)!
    }
    func download(page: Page, ifNoneMatch etag: String?) async throws -> RemoteDocument? {
        downloads.append((page.id, etag))
        if failingPages.contains(page.id) { throw Failure.unavailable }
        if etag != nil && unchangedPages.contains(page.id) { return nil }
        return RemoteDocument(markdown: "remote \(page.id)", etag: "\"remote \(page.id)\"")
    }
    func upload(page: Page, markdown: String, etag: String?) async throws -> String? {
        uploads.append((page.id, etag))
        return "\"saved\""
    }
}

private actor AccountSyncCheckpoints {
    private(set) var snapshots: [AccountSnapshot] = []
    func save(_ snapshot: AccountSnapshot) { snapshots.append(snapshot) }
}

@Test func accountSyncDownloadsEveryCollectiveAndPreservesUnchangedContent() async throws {
    let groups = [Collective(id: 1, name: "Team"), Collective(id: 2, name: "Other")]
    var snapshot = AccountSnapshot()
    snapshot.documents["1"] = CachedDocument(page: accountSyncPage(1), collectiveID: 1,
        markdown: "unchanged", etag: "\"base\"")
    let api = AccountSyncStub(groups: groups,
        listings: [1: [accountSyncPage(1, title: "Renamed"), accountSyncPage(2)], 2: [accountSyncPage(3)]],
        unchangedPages: [1])
    let checkpoints = AccountSyncCheckpoints()
    let result = try await AccountSynchronizer.synchronize(snapshot: snapshot, api: api) { await checkpoints.save($0) }
    #expect(result.failures.isEmpty)
    #expect(result.snapshot.collectives == groups)
    #expect(await api.requestedGroups == [1, 2])
    #expect(await api.downloads.map(\.0) == [1, 2, 3])
    #expect(await api.downloads.first?.1 == "\"base\"")
    #expect(result.snapshot.documents["1"]?.markdown == "unchanged")
    #expect(result.snapshot.documents["1"]?.etag == "\"base\"")
    #expect(result.snapshot.documents["1"]?.page.title == "Renamed")
    #expect(result.snapshot.documents["3"]?.markdown == "remote 3")
    #expect(await checkpoints.snapshots.count == 6)
}

@Test func accountSyncPrunesDeletedCleanItemsAndKeepsLocalWorkVisible() async throws {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 1, name: "Team"), Collective(id: 2, name: "Deleted"), Collective(id: 3, name: "Gone")]
    snapshot.pages = ["1": [accountSyncPage(1), accountSyncPage(2)], "2": [accountSyncPage(3), accountSyncPage(4)], "3": [accountSyncPage(5)]]
    for id in 1...5 {
        snapshot.documents[String(id)] = CachedDocument(page: accountSyncPage(id), collectiveID: id < 3 ? 1 : id < 5 ? 2 : 3,
            markdown: "base", etag: "\"base\"", draft: id == 2 || id == 4 ? "draft" : nil)
    }
    let api = AccountSyncStub(listings: [1: []])
    let result = try await AccountSynchronizer.synchronize(snapshot: snapshot, api: api) { _ in }
    #expect(result.snapshot.collectives.map(\.id) == [1, 2])
    #expect(Set(result.snapshot.documents.keys) == ["2", "4"])
    #expect(result.snapshot.pages["1"]?.map(\.id) == [2])
    #expect(result.snapshot.pages["2"]?.map(\.id) == [4])
    #expect(result.snapshot.pages["3"] == nil)
    #expect(await api.uploads.isEmpty)
}

@Test func accountSyncRetainsSuccessesAfterPageAndCollectiveFailure() async throws {
    let groups = (1...3).map { Collective(id: $0, name: "Group \($0)") }
    var snapshot = AccountSnapshot()
    snapshot.pages["2"] = [accountSyncPage(99)]
    let api = AccountSyncStub(groups: groups,
        listings: [1: [accountSyncPage(1), accountSyncPage(2), accountSyncPage(3)], 3: [accountSyncPage(4)]],
        failingPages: [2], failingGroups: [2])
    let checkpoints = AccountSyncCheckpoints()
    let result = try await AccountSynchronizer.synchronize(snapshot: snapshot, api: api) { await checkpoints.save($0) }
    #expect(result.failures.count == 2)
    #expect(result.failures[0].pageID == 2)
    #expect(result.failures[1].collectiveID == 2)
    #expect(result.failures[1].pageID == nil)
    #expect(Set(result.snapshot.documents.keys) == ["1", "3", "4"])
    #expect(result.snapshot.pages["2"] == snapshot.pages["2"])
    #expect(await checkpoints.snapshots.last?.documents["4"]?.markdown == "remote 4")
}

@Test func accountSyncUploadsDraftsAndDoesNotTouchConflicts() async throws {
    var snapshot = AccountSnapshot()
    let conflict = RemoteDocument(markdown: "other edit", etag: "\"other\"")
    snapshot.documents["1"] = CachedDocument(page: accountSyncPage(1), collectiveID: 1,
        markdown: "base", etag: "\"base\"", draft: "local edit")
    snapshot.documents["2"] = CachedDocument(page: accountSyncPage(2), collectiveID: 1,
        markdown: "base", etag: "\"base\"", draft: "local edit", conflict: conflict)
    let api = AccountSyncStub(listings: [1: [accountSyncPage(1), accountSyncPage(2)]])
    let result = try await AccountSynchronizer.synchronize(snapshot: snapshot, api: api) { _ in }
    #expect(result.snapshot.documents["1"]?.draft == nil)
    #expect(result.snapshot.documents["1"]?.markdown == "local edit")
    #expect(result.snapshot.documents["2"]?.conflict == conflict)
    #expect(await api.downloads.isEmpty)
    #expect(await api.uploads.count == 1)
    #expect(await api.uploads.first?.1 == "\"base\"")
}

@Test func accountSyncStopsBeforeNetworkWhenCancelled() async throws {
    let api = AccountSyncStub(listings: [1: [accountSyncPage(1)]])
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: api) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await api.downloads.isEmpty)
}

@Test func accountSyncStopsWhenCheckpointFails() async throws {
    let api = AccountSyncStub(listings: [1: [accountSyncPage(1)]])
    await #expect(throws: AccountSyncStub.Failure.self) {
        try await AccountSynchronizer.synchronize(snapshot: AccountSnapshot(), api: api) { _ in
            throw AccountSyncStub.Failure.unavailable
        }
    }
    #expect(await api.requestedGroups.isEmpty)
}
