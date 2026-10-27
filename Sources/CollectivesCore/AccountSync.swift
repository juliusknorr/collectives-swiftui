import Foundation

public protocol AccountSyncAPI: DocumentAPI {
    func collectives() async throws -> [Collective]
    func pages(collectiveID: Int) async throws -> [Page]
}

extension CollectivesClient: AccountSyncAPI {}

public struct AccountSyncFailure: Sendable {
    public let collectiveID: Int
    public let pageID: Int?
    public let message: String
    public let requiresSignIn: Bool

    init(collectiveID: Int, pageID: Int?, error: any Error) {
        self.collectiveID = collectiveID
        self.pageID = pageID
        message = error.localizedDescription
        if case CollectivesError.http(401) = error { requiresSignIn = true }
        else { requiresSignIn = false }
    }
}

public struct AccountSyncResult: Sendable {
    public let snapshot: AccountSnapshot
    public let failures: [AccountSyncFailure]
}

public struct AccountSyncProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case listingCollectives, listingPages, downloading, uploading, checking, saving, finished
    }
    public var phase: Phase
    public var collective: Collective?
    public var page: Page?
    public var activePages: [Page] = []
    public var completedPages: Int = 0
    public var totalPages: Int?
    public var completedCollectives: Int = 0
    public var totalCollectives: Int?
    public var failureCount: Int = 0

    public init(phase: Phase, collective: Collective? = nil, page: Page? = nil,
                completedPages: Int = 0, totalPages: Int? = nil,
                completedCollectives: Int = 0, totalCollectives: Int? = nil, failureCount: Int = 0) {
        self.phase = phase; self.collective = collective; self.page = page
        self.completedPages = completedPages; self.totalPages = totalPages
        self.completedCollectives = completedCollectives; self.totalCollectives = totalCollectives
        self.failureCount = failureCount
    }
}

public enum AccountSynchronizer {
    public static func synchronize(
        snapshot: AccountSnapshot,
        api: any AccountSyncAPI,
        progress: @Sendable (AccountSyncProgress) async -> Void = { _ in },
        checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws -> AccountSyncResult {
        try Task.checkCancellation()
        var status = AccountSyncProgress(phase: .listingCollectives)
        await progress(status)
        let collectives = try await api.collectives()
        var updated = snapshot
        var failures: [AccountSyncFailure] = []
        updated.replaceCollectives(collectives)
        try await checkpoint(updated)
        status.totalCollectives = collectives.count

        for collective in collectives {
            try Task.checkCancellation()
            status.phase = .listingPages
            status.collective = collective
            status.page = nil
            status.completedPages = 0
            status.totalPages = nil
            await progress(status)
            let pages: [Page]
            do {
                pages = try await api.pages(collectiveID: collective.id)
            } catch {
                try rethrowCancellation(error)
                failures.append(AccountSyncFailure(collectiveID: collective.id, pageID: nil, error: error))
                status.failureCount = failures.count
                status.completedCollectives += 1
                await progress(status)
                continue
            }
            try await synchronize(pages: pages, collectiveID: collective.id, uploadDrafts: true,
                                  snapshot: &updated, failures: &failures, status: &status,
                                  api: api, progress: progress, checkpoint: checkpoint)
            status.completedCollectives += 1
        }
        try Task.checkCancellation()
        status.phase = .finished
        status.page = nil
        await progress(status)
        return AccountSyncResult(snapshot: updated, failures: failures)
    }

    /// Downloads one collective for offline use, leaving drafts and conflicts for a full sync.
    public static func download(
        collectiveID: Int,
        snapshot: AccountSnapshot,
        api: any AccountSyncAPI,
        progress: @Sendable (AccountSyncProgress) async -> Void = { _ in },
        checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws -> AccountSyncResult {
        try Task.checkCancellation()
        var status = AccountSyncProgress(phase: .listingPages,
            collective: snapshot.collectives.first { $0.id == collectiveID }, totalCollectives: 1)
        await progress(status)
        let pages = try await api.pages(collectiveID: collectiveID)
        var updated = snapshot
        var failures: [AccountSyncFailure] = []
        try await synchronize(pages: pages, collectiveID: collectiveID, uploadDrafts: false,
                              snapshot: &updated, failures: &failures, status: &status,
                              api: api, progress: progress, checkpoint: checkpoint)
        try Task.checkCancellation()
        status.phase = .finished
        status.page = nil
        status.completedCollectives = 1
        await progress(status)
        return AccountSyncResult(snapshot: updated, failures: failures)
    }

    private static func synchronize(
        pages: [Page], collectiveID: Int, uploadDrafts: Bool,
        snapshot updated: inout AccountSnapshot, failures: inout [AccountSyncFailure],
        status: inout AccountSyncProgress, api: any AccountSyncAPI,
        progress: @Sendable (AccountSyncProgress) async -> Void,
        checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws {
        updated.replacePages(pages, collectiveID: collectiveID)
        try await checkpoint(updated)
        try await synchronizeDocuments(pages: pages, collectiveID: collectiveID, uploadDrafts: uploadDrafts,
                                       snapshot: &updated, failures: &failures, status: &status,
                                       api: api, progress: progress, checkpoint: checkpoint)
    }

    /// Uploads pending drafts without refreshing metadata or touching clean pages.
    public static func synchronizeDrafts(
        snapshot: AccountSnapshot,
        api: any DocumentAPI,
        progress: @Sendable (AccountSyncProgress) async -> Void = { _ in },
        checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws -> AccountSyncResult {
        try Task.checkCancellation()
        let drafts = snapshot.documents.values.filter { $0.draft != nil && $0.conflict == nil }
        let groups = Dictionary(grouping: drafts, by: \.collectiveID)
        var updated = snapshot
        var failures: [AccountSyncFailure] = []
        var status = AccountSyncProgress(phase: .uploading, totalCollectives: groups.count)
        for collectiveID in groups.keys.sorted() {
            try Task.checkCancellation()
            status.collective = snapshot.collectives.first { $0.id == collectiveID }
            status.page = nil
            status.completedPages = 0
            let pages = groups[collectiveID, default: []].map(\.page).sorted { $0.id < $1.id }
            try await synchronizeDocuments(pages: pages, collectiveID: collectiveID, uploadDrafts: true,
                                           snapshot: &updated, failures: &failures, status: &status,
                                           api: api, progress: progress, checkpoint: checkpoint)
            status.completedCollectives += 1
        }
        try Task.checkCancellation()
        status.phase = .finished
        status.page = nil
        await progress(status)
        return AccountSyncResult(snapshot: updated, failures: failures)
    }

    private struct PageJob: Sendable {
        let page: Page
        let document: CachedDocument?

        func phase(uploadDrafts: Bool) -> AccountSyncProgress.Phase {
            guard let document else { return .downloading }
            return uploadDrafts && document.draft != nil && document.conflict == nil ? .uploading : .checking
        }
    }
    private struct PageResult: Sendable {
        let page: Page
        let document: CachedDocument?
        let failure: AccountSyncFailure?
    }

    private static func synchronizeDocuments(
        pages: [Page], collectiveID: Int, uploadDrafts: Bool,
        snapshot updated: inout AccountSnapshot, failures: inout [AccountSyncFailure],
        status: inout AccountSyncProgress, api: any DocumentAPI,
        progress: @Sendable (AccountSyncProgress) async -> Void,
        checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws {
        var seen: Set<Int> = []
        let jobs = pages.filter { seen.insert($0.id).inserted }.map {
            PageJob(page: $0, document: updated.documents[String($0.id)])
        }
        status.totalPages = jobs.count
        status.activePages = []
        await progress(status)
        try await withThrowingTaskGroup(of: PageResult.self) { group in
            var next = 0
            for job in jobs.prefix(3) {
                try Task.checkCancellation()
                status.page = job.page
                status.phase = job.phase(uploadDrafts: uploadDrafts)
                status.activePages.append(job.page)
                await progress(status)
                try Task.checkCancellation()
                group.addTask {
                    try await synchronize(job: job, collectiveID: collectiveID, uploadDrafts: uploadDrafts, api: api)
                }
                next += 1
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let document = result.document { updated.documents[String(result.page.id)] = document }
                if let failure = result.failure { failures.append(failure) }
                status.failureCount = failures.count
                status.page = result.page
                status.activePages.removeAll { $0.id == result.page.id }
                status.phase = .saving
                await progress(status)
                try await checkpoint(updated)
                try Task.checkCancellation()
                status.completedPages += 1
                await progress(status)
                if next < jobs.count {
                    let job = jobs[next]
                    status.page = job.page
                    status.phase = job.phase(uploadDrafts: uploadDrafts)
                    status.activePages.append(job.page)
                    await progress(status)
                    try Task.checkCancellation()
                    group.addTask {
                        try await synchronize(job: job, collectiveID: collectiveID, uploadDrafts: uploadDrafts, api: api)
                    }
                    next += 1
                } else if let page = status.activePages.first, let job = jobs.first(where: { $0.page.id == page.id }) {
                    status.page = job.page
                    status.phase = job.phase(uploadDrafts: uploadDrafts)
                    await progress(status)
                }
            }
        }
    }

    private static func synchronize(job: PageJob, collectiveID: Int, uploadDrafts: Bool, api: any DocumentAPI) async throws -> PageResult {
        do {
            try Task.checkCancellation()
            let document: CachedDocument
            if let cached = job.document {
                document = uploadDrafts || !cached.hasLocalChanges
                    ? try await DocumentSynchronizer.synchronize(document: cached, api: api) : cached
            } else {
                let remote = try await api.download(page: job.page)
                document = CachedDocument(page: job.page, collectiveID: collectiveID,
                    markdown: remote.markdown, etag: remote.etag)
            }
            try Task.checkCancellation()
            return PageResult(page: job.page, document: document, failure: nil)
        } catch {
            try rethrowCancellation(error)
            return PageResult(page: job.page, document: nil,
                failure: AccountSyncFailure(collectiveID: collectiveID, pageID: job.page.id, error: error))
        }
    }

    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
    }
}
