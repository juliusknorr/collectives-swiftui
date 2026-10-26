import Foundation

public protocol DocumentAPI: Sendable {
    func download(page: Page) async throws -> RemoteDocument
    func upload(page: Page, markdown: String, etag: String?) async throws -> String?
}

extension CollectivesClient: DocumentAPI {}

public enum DocumentSynchronizer {
    public static func synchronize(document: CachedDocument, api: any DocumentAPI) async throws -> CachedDocument {
        guard document.conflict == nil else { return document }
        var updated = document
        guard let draft = document.draft else {
            let remote = try await api.download(page: document.page)
            updated.markdown = remote.markdown
            updated.etag = remote.etag
            return updated
        }

        var revision = document.etag
        if !isStrong(revision) {
            let remote = try await api.download(page: document.page)
            if remote.markdown == draft { return reconcile(document: document, remote: remote) }
            guard remote.markdown == document.markdown else {
                updated.conflict = remote
                return updated
            }
            revision = remote.etag
        }
        guard isStrong(revision) else { throw CollectivesError.missingETag }

        do {
            let newRevision = try await api.upload(page: document.page, markdown: draft, etag: revision)
            updated.markdown = draft
            updated.draft = nil
            updated.etag = newRevision
        } catch CollectivesError.conflict {
            return reconcile(document: document, remote: try await api.download(page: document.page))
        } catch CollectivesError.http(412) {
            return reconcile(document: document, remote: try await api.download(page: document.page))
        }
        return updated
    }

    private static func reconcile(document: CachedDocument, remote: RemoteDocument) -> CachedDocument {
        var updated = document
        if remote.markdown == document.draft {
            updated.markdown = remote.markdown
            updated.etag = remote.etag
            updated.draft = nil
        } else {
            updated.conflict = remote
        }
        return updated
    }

    private static func isStrong(_ revision: String?) -> Bool {
        guard let revision else { return false }
        return !revision.isEmpty && !revision.hasPrefix("W/")
    }
}
