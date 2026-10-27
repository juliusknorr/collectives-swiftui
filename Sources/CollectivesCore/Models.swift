import Foundation

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let serverURL: URL
    public let userID: String
    public init(id: UUID = UUID(), serverURL: URL, userID: String) {
        self.id = id; self.serverURL = serverURL; self.userID = userID
    }
}
public struct Collective: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let emoji: String?
    public let canEdit: Bool
    public init(id: Int, name: String, emoji: String? = nil, canEdit: Bool = true) {
        self.id = id; self.name = name; self.emoji = emoji; self.canEdit = canEdit
    }
}
public struct Page: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let timestamp: Int?
    public let lastUserDisplayName: String?
    public let emoji: String?
    public let fileName: String
    public let filePath: String
    public let collectivePath: String?
    public let parentId: Int
    public init(id: Int, title: String, fileName: String, filePath: String, collectivePath: String?, parentId: Int = 0, emoji: String? = nil, timestamp: Int? = nil, lastUserDisplayName: String? = nil) {
        self.id = id; self.title = title; self.timestamp = timestamp; self.lastUserDisplayName = lastUserDisplayName; self.emoji = emoji; self.fileName = fileName; self.filePath = filePath
        self.collectivePath = collectivePath; self.parentId = parentId
    }
}
public struct RemoteDocument: Codable, Equatable, Sendable {
    public let markdown: String
    public let etag: String?
    public init(markdown: String, etag: String?) { self.markdown = markdown; self.etag = etag }
}
public struct CachedDocument: Codable, Equatable, Sendable {
    public var page: Page
    public var collectiveID: Int
    public var markdown: String
    public var etag: String?
    public var draft: String?
    public var conflict: RemoteDocument?
    public init(page: Page, collectiveID: Int, markdown: String, etag: String?, draft: String? = nil, conflict: RemoteDocument? = nil) {
        self.page = page; self.collectiveID = collectiveID; self.markdown = markdown; self.etag = etag
        self.draft = draft; self.conflict = conflict
    }
}
public struct AccountSnapshot: Codable, Sendable {
    public var collectives: [Collective] = []
    public var pages: [String: [Page]] = [:]
    public var documents: [String: CachedDocument] = [:]
    public var textSourceBackups: [String: String]?
    public init() {}
}
public extension CachedDocument {
    var hasLocalChanges: Bool { draft != nil || conflict != nil }
}
public extension AccountSnapshot {
    /// Collectives removed on the server stay visible while they hold drafts or conflicts.
    mutating func replaceCollectives(_ remote: [Collective]) {
        let remoteIDs = Set(remote.map(\.id))
        let unsyncedIDs = Set(documents.values.filter(\.hasLocalChanges).map(\.collectiveID))
        collectives = remote + collectives.filter { !remoteIDs.contains($0.id) && unsyncedIDs.contains($0.id) }
        documents = documents.filter { remoteIDs.contains($0.value.collectiveID) || $0.value.hasLocalChanges }
        for key in Array(pages.keys) where !remoteIDs.contains(Int(key) ?? -1) {
            let retained = (pages[key] ?? []).filter { documents[String($0.id)]?.hasLocalChanges ?? false }
            pages[key] = retained.isEmpty ? nil : retained
        }
    }
    /// Pages removed on the server stay visible while they hold drafts or conflicts.
    /// Cached documents follow renames and moves without touching their content.
    mutating func replacePages(_ remote: [Page], collectiveID: Int) {
        let remoteIDs = Set(remote.map(\.id))
        let retained = (pages[String(collectiveID)] ?? []).filter {
            !remoteIDs.contains($0.id) && (documents[String($0.id)]?.hasLocalChanges ?? false)
        }
        pages[String(collectiveID)] = remote + retained
        documents = documents.filter {
            $0.value.collectiveID != collectiveID || remoteIDs.contains($0.value.page.id) || $0.value.hasLocalChanges
        }
        for page in remote {
            documents[String(page.id)]?.page = page
            documents[String(page.id)]?.collectiveID = collectiveID
        }
    }
}
public enum CollectivesError: Error, LocalizedError, Sendable {
    case invalidServer, unsafeURL, http(Int), invalidResponse, missingETag, conflict, missingDocument, credential(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter an HTTPS Nextcloud server URL (HTTP is allowed only for localhost)."
        case .unsafeURL: "The server returned a URL outside the trusted server."
        case .http(let code): "The server returned HTTP \(code)."
        case .invalidResponse: "The server returned an unexpected response."
        case .missingETag: "The server did not provide a revision. Saving is disabled to protect remote changes."
        case .conflict: "The page changed on the server. Your local draft has been preserved."
        case .missingDocument: "Download this page before editing offline."
        case .credential(let code): "Keychain operation failed (\(code))."
        }
    }
}
