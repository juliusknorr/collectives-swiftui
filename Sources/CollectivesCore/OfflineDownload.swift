import Foundation

public protocol CollectiveDownloadAPI: Sendable {
    func pages(collectiveID: Int) async throws -> [Page]
    func download(page: Page) async throws -> RemoteDocument
}

extension CollectivesClient: CollectiveDownloadAPI {}

public enum OfflineDownloader {
    public static func download(
        collectiveID: Int,
        snapshot: AccountSnapshot,
        api: any CollectiveDownloadAPI,
        checkpoint: @Sendable (AccountSnapshot) async throws -> Void
    ) async throws -> AccountSnapshot {
        try Task.checkCancellation()
        let pages = try await api.pages(collectiveID: collectiveID)
        var updated = snapshot
        updated.pages[String(collectiveID)] = pages
        for page in pages {
            let key = String(page.id)
            if var document = updated.documents[key] {
                document.page = page
                document.collectiveID = collectiveID
                updated.documents[key] = document
            }
        }
        try await checkpoint(updated)

        for page in pages {
            try Task.checkCancellation()
            let key = String(page.id)
            let existing = updated.documents[key]
            if existing?.draft == nil && existing?.conflict == nil {
                let remote = try await api.download(page: page)
                updated.documents[key] = CachedDocument(
                    page: page, collectiveID: collectiveID,
                    markdown: remote.markdown, etag: remote.etag
                )
            }
            try await checkpoint(updated)
        }
        return updated
    }
}
