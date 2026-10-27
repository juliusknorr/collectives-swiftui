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
        let collectiveIDs = Set(collectives.map(\.id))
        // Keep deleted items with local work visible until the user resolves it.
        let preservedCollectives = snapshot.collectives.filter { collective in
            !collectiveIDs.contains(collective.id) && snapshot.documents.values.contains {
                $0.collectiveID == collective.id && hasLocalChanges($0)
            }
        }
        updated.collectives = collectives + preservedCollectives
        for key in Array(updated.documents.keys) {
            guard let document = updated.documents[key], !collectiveIDs.contains(document.collectiveID),
                  !hasLocalChanges(document) else { continue }
            updated.documents.removeValue(forKey: key)
        }
        for key in Array(updated.pages.keys) where !collectiveIDs.contains(Int(key) ?? -1) {
            let retained = (updated.pages[key] ?? []).filter { page in
                updated.documents[String(page.id)].map(hasLocalChanges) ?? false
            }
            updated.pages[key] = retained.isEmpty ? nil : retained
        }
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
            let pageIDs = Set(pages.map(\.id))
            let retainedPages = (updated.pages[String(collective.id)] ?? []).filter { page in
                !pageIDs.contains(page.id) && (updated.documents[String(page.id)].map(hasLocalChanges) ?? false)
            }
            updated.pages[String(collective.id)] = pages + retainedPages
            for key in Array(updated.documents.keys) {
                guard let document = updated.documents[key], document.collectiveID == collective.id,
                      !pageIDs.contains(document.page.id), !hasLocalChanges(document) else { continue }
                updated.documents.removeValue(forKey: key)
            }
            for page in pages {
                let key = String(page.id)
                if var document = updated.documents[key] {
                    document.page = page
                    document.collectiveID = collective.id
                    updated.documents[key] = document
                }
            }
            try await checkpoint(updated)
            for page in pages {
                try Task.checkCancellation()
                let key = String(page.id)
                do {
                    if let document = updated.documents[key] {
                        updated.documents[key] = try await DocumentSynchronizer.synchronize(document: document, api: api)
                    } else {
                        let remote = try await api.download(page: page)
                        updated.documents[key] = CachedDocument(page: page, collectiveID: collective.id,
                            markdown: remote.markdown, etag: remote.etag)
                    }
                } catch {
                    try rethrowCancellation(error)
                    failures.append(AccountSyncFailure(collectiveID: collective.id, pageID: page.id, message: error.localizedDescription))
                }
                try await checkpoint(updated)
            }
        }
        return AccountSyncResult(snapshot: updated, failures: failures)
    }

    private static func hasLocalChanges(_ document: CachedDocument) -> Bool {
        document.draft != nil || document.conflict != nil
    }

    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
    }
}
