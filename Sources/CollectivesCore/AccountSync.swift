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
}

public struct AccountSyncResult: Sendable {
    public let snapshot: AccountSnapshot
    public let failures: [AccountSyncFailure]
}

public enum AccountSynchronizer {
    public static func synchronize(
        snapshot: AccountSnapshot,
        api: any AccountSyncAPI,
        checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws -> AccountSyncResult {
        try Task.checkCancellation()
        let collectives = try await api.collectives()
        var updated = snapshot
        var failures: [AccountSyncFailure] = []
        updated.replaceCollectives(collectives)
        try await checkpoint(updated)

        for collective in collectives {
            try Task.checkCancellation()
            let pages: [Page]
            do {
                pages = try await api.pages(collectiveID: collective.id)
            } catch {
                try rethrowCancellation(error)
                failures.append(AccountSyncFailure(collectiveID: collective.id, pageID: nil, message: error.localizedDescription))
                continue
            }
            try await synchronize(pages: pages, collectiveID: collective.id, uploadDrafts: true,
                                  snapshot: &updated, failures: &failures, api: api, checkpoint: checkpoint)
        }
        return AccountSyncResult(snapshot: updated, failures: failures)
    }

    /// Downloads one collective for offline use, leaving drafts and conflicts for a full sync.
    public static func download(
        collectiveID: Int,
        snapshot: AccountSnapshot,
        api: any AccountSyncAPI,
        checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws -> AccountSyncResult {
        try Task.checkCancellation()
        let pages = try await api.pages(collectiveID: collectiveID)
        var updated = snapshot
        var failures: [AccountSyncFailure] = []
        try await synchronize(pages: pages, collectiveID: collectiveID, uploadDrafts: false,
                              snapshot: &updated, failures: &failures, api: api, checkpoint: checkpoint)
        return AccountSyncResult(snapshot: updated, failures: failures)
    }

    private static func synchronize(
        pages: [Page], collectiveID: Int, uploadDrafts: Bool,
        snapshot updated: inout AccountSnapshot, failures: inout [AccountSyncFailure],
        api: any AccountSyncAPI, checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws {
        updated.replacePages(pages, collectiveID: collectiveID)
        try await checkpoint(updated)
        for page in pages {
            try Task.checkCancellation()
            let key = String(page.id)
            do {
                if let document = updated.documents[key] {
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
                failures.append(AccountSyncFailure(collectiveID: collectiveID, pageID: page.id, message: error.localizedDescription))
            }
            try await checkpoint(updated)
        }
    }

    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
    }
}
