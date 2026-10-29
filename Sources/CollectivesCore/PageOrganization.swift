import Foundation

public protocol PageOrganizationAPI: Sendable {
    func pages(collectiveID: Int) async throws -> [Page]
    func trashedPages(collectiveID: Int) async throws -> [Page]
    func movePage(collectiveID: Int, pageID: Int, parentID: Int) async throws -> Page
    func trashPage(collectiveID: Int, pageID: Int) async throws
    func restorePage(collectiveID: Int, pageID: Int) async throws -> Page
}

extension CollectivesClient: PageOrganizationAPI {
    public func trashedPages(collectiveID: Int) async throws -> [Page] {
        struct Result: Decodable { let pages: [Page] }
        return try await ocs(Result.self, path: organizationPath(collectiveID) + ["trash"]).pages
    }
    public func movePage(collectiveID: Int, pageID: Int, parentID: Int) async throws -> Page {
        struct Result: Decodable { let page: Page }
        return try await ocs(Result.self, path: organizationPath(collectiveID) + [String(pageID)],
            method: "PUT", body: JSONEncoder().encode(["parentId": parentID])).page
    }
    public func trashPage(collectiveID: Int, pageID: Int) async throws {
        struct Result: Decodable {}
        _ = try await ocs(Result.self, path: organizationPath(collectiveID) + [String(pageID)], method: "DELETE")
    }
    public func restorePage(collectiveID: Int, pageID: Int) async throws -> Page {
        struct Result: Decodable { let page: Page }
        return try await ocs(Result.self, path: organizationPath(collectiveID) + ["trash", String(pageID)], method: "PATCH").page
    }
    private func organizationPath(_ collectiveID: Int) -> [String] {
        ["ocs", "v2.php", "apps", "collectives", "api", "v1.0", "collectives", String(collectiveID), "pages"]
    }
}

public enum PageOrganizationError: Error, LocalizedError, Sendable {
    case missingPage, landingPage, invalidParent, localChanges, readOnly, unconfirmed(String)
    public var errorDescription: String? {
        switch self {
        case .missingPage: "This page is no longer available. Refresh the page list before trying again."
        case .landingPage: "The collective landing page cannot be moved or trashed."
        case .invalidParent: "Choose an available parent outside this page's descendants."
        case .localChanges: "Sync or export drafts and resolve conflicts in this page and its subpages before moving them to trash."
        case .readOnly: "You do not have permission to organize pages in this collective."
        case .unconfirmed(let reason): "The change could not be confirmed. Refresh before trying again. \(reason)"
        }
    }
}

public struct OrganizedPage: Sendable {
    public let snapshot: AccountSnapshot
    public let warnings: [String]
}

public enum PageOrganizer {
    public static func move(pageID: Int, parentID: Int, collectiveID: Int,
                            snapshot: AccountSnapshot, api: any PageOrganizationAPI) async throws -> OrganizedPage {
        try writable(snapshot, collectiveID)
        let before = try await api.pages(collectiveID: collectiveID)
        guard let original = before.first(where: { $0.id == pageID }) else { throw PageOrganizationError.missingPage }
        guard original.parentId != 0 else { throw PageOrganizationError.landingPage }
        guard before.contains(where: { $0.id == parentID }),
              !PageTree.path(to: parentID, pages: before).contains(where: { $0.id == pageID }) else {
            throw PageOrganizationError.invalidParent
        }
        if original.parentId == parentID { return result(before, collectiveID, snapshot) }
        let moved: Page
        try Task.checkCancellation()
        do { moved = try await api.movePage(collectiveID: collectiveID, pageID: pageID, parentID: parentID) }
        catch {
            if definitive(error) { throw error }
            try Task.checkCancellation()
            if let refreshed = try? await api.pages(collectiveID: collectiveID),
               refreshed.contains(where: { $0.id == pageID && $0.parentId == parentID }) {
                return result(refreshed, collectiveID, snapshot)
            }
            throw PageOrganizationError.unconfirmed(error.localizedDescription)
        }
        guard moved.id == pageID, moved.parentId == parentID else {
            throw PageOrganizationError.unconfirmed("Unexpected moved page.")
        }
        if let refreshed = try? await api.pages(collectiveID: collectiveID),
           refreshed.contains(where: { $0.id == pageID && $0.parentId == parentID }) {
            return result(refreshed, collectiveID, snapshot)
        }
        // A moved page with children is represented by its folder's Readme.md.
        // Its returned folder path also determines every descendant's new path.
        let destinationPath = moved.fileName == "Readme.md"
            ? moved.filePath.split(separator: "/").dropLast().joined(separator: "/")
            : moved.filePath
        let remapped = before.map { page -> Page in
            if page.id == pageID { return moved }
            if page.id == parentID, page.fileName != "Readme.md" {
                return Page(id: page.id, title: page.title, fileName: "Readme.md", filePath: destinationPath,
                    collectivePath: moved.collectivePath, parentId: page.parentId, emoji: page.emoji,
                    timestamp: page.timestamp, lastUserDisplayName: page.lastUserDisplayName)
            }
            guard !original.filePath.isEmpty,
                  PageTree.path(to: page.id, pages: before).contains(where: { $0.id == pageID }),
                  page.filePath == original.filePath || page.filePath.hasPrefix(original.filePath + "/") else { return page }
            return Page(id: page.id, title: page.title, fileName: page.fileName,
                filePath: moved.filePath + page.filePath.dropFirst(original.filePath.count),
                collectivePath: moved.collectivePath, parentId: page.parentId, emoji: page.emoji,
                timestamp: page.timestamp, lastUserDisplayName: page.lastUserDisplayName)
        }
        return result(remapped, collectiveID, snapshot,
            warnings: ["Move confirmed. Refresh when connected to check the latest page paths."])
    }

    public static func trash(pageID: Int, collectiveID: Int, snapshot: AccountSnapshot,
                             api: any PageOrganizationAPI) async throws -> OrganizedPage {
        try writable(snapshot, collectiveID)
        let before = try await api.pages(collectiveID: collectiveID)
        guard let original = before.first(where: { $0.id == pageID }) else { throw PageOrganizationError.missingPage }
        guard original.parentId != 0 else { throw PageOrganizationError.landingPage }
        let subtree = Set(before.filter {
            PageTree.path(to: $0.id, pages: before).contains(where: { $0.id == pageID })
        }.map(\.id))
        guard !snapshot.documents.values.contains(where: {
            $0.collectiveID == collectiveID && subtree.contains($0.page.id) && $0.hasLocalChanges
        }) else { throw PageOrganizationError.localChanges }
        try Task.checkCancellation()
        do { try await api.trashPage(collectiveID: collectiveID, pageID: pageID) }
        catch {
            if definitive(error) { throw error }
            try Task.checkCancellation()
            if let trashed = try? await api.trashedPages(collectiveID: collectiveID),
               trashed.contains(where: { $0.id == pageID }),
               let refreshed = try? await api.pages(collectiveID: collectiveID),
               !refreshed.contains(where: { $0.id == pageID }) {
                return result(refreshed, collectiveID, snapshot)
            }
            throw PageOrganizationError.unconfirmed(error.localizedDescription)
        }
        if let refreshed = try? await api.pages(collectiveID: collectiveID),
           !refreshed.contains(where: { $0.id == pageID }) {
            return result(refreshed, collectiveID, snapshot)
        }
        return result(before.filter { !subtree.contains($0.id) }, collectiveID, snapshot,
            warnings: ["Moved to trash. Refresh when connected to check the latest page list."])
    }

    public static func restore(pageID: Int, collectiveID: Int, snapshot: AccountSnapshot,
                               api: any PageOrganizationAPI) async throws -> OrganizedPage {
        try writable(snapshot, collectiveID)
        let trash = try await api.trashedPages(collectiveID: collectiveID)
        guard trash.contains(where: { $0.id == pageID }) else { throw PageOrganizationError.missingPage }
        let restored: Page
        try Task.checkCancellation()
        do { restored = try await api.restorePage(collectiveID: collectiveID, pageID: pageID) }
        catch {
            if definitive(error) { throw error }
            try Task.checkCancellation()
            if let refreshed = try? await api.pages(collectiveID: collectiveID),
               refreshed.contains(where: { $0.id == pageID }) {
                return result(refreshed, collectiveID, snapshot)
            }
            throw PageOrganizationError.unconfirmed(error.localizedDescription)
        }
        guard restored.id == pageID else { throw PageOrganizationError.unconfirmed("Unexpected restored page.") }
        if let refreshed = try? await api.pages(collectiveID: collectiveID),
           refreshed.contains(where: { $0.id == pageID }) {
            return result(refreshed, collectiveID, snapshot)
        }
        // Do not prune unrelated cached pages when the post-write listing is unavailable.
        let known = snapshot.pages[String(collectiveID)] ?? []
        return result(known.filter { $0.id != pageID } + [restored], collectiveID, snapshot,
            warnings: ["Restore confirmed. Refresh when connected to load restored subpages and current paths."])
    }

    private static func writable(_ snapshot: AccountSnapshot, _ collectiveID: Int) throws {
        if snapshot.collectives.first(where: { $0.id == collectiveID })?.canEdit != true {
            throw PageOrganizationError.readOnly
        }
    }
    private static func definitive(_ error: any Error) -> Bool {
        if case .http(let code) = error as? CollectivesError {
            return (400..<500).contains(code) && code != 408
        }
        return false
    }
    private static func result(_ pages: [Page], _ collectiveID: Int, _ snapshot: AccountSnapshot,
                               warnings: [String] = []) -> OrganizedPage {
        var next = snapshot
        next.replacePages(pages, collectiveID: collectiveID)
        return OrganizedPage(snapshot: next, warnings: warnings)
    }
}
