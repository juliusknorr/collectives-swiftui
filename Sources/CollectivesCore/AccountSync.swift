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
        status.totalPages = pages.count
        await progress(status)
        for page in pages {
            try Task.checkCancellation()
            let key = String(page.id)
            let document = updated.documents[key]
            status.page = page
            status.phase = document == nil ? .downloading
                : (uploadDrafts && document?.draft != nil && document?.conflict == nil ? .uploading : .checking)
            await progress(status)
            do {
                if let document {
                    if uploadDrafts || !document.hasLocalChanges {
                        updated.documents[key] = try await DocumentSynchronizer.synchronize(document: document, api: api)
                    }
                } else {
                    let remote = try await api.download(page: page)
                    updated.documents[key] = CachedDocument(page: page, collectiveID: collectiveID,
                        markdown: remote.markdown, etag: remote.etag)
                }
            } catch {
                try rethrowCancellation(error)
                failures.append(AccountSyncFailure(collectiveID: collectiveID, pageID: page.id, error: error))
            }
            status.failureCount = failures.count
            status.phase = .saving
            await progress(status)
            try await checkpoint(updated)
            try Task.checkCancellation()
            status.completedPages += 1
            await progress(status)
        }
    }

    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
    }
}
