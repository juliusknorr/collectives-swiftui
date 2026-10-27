import Foundation

public protocol PageRenamingAPI: Sendable {
    func pages(collectiveID: Int) async throws -> [Page]
    func renamePage(collectiveID: Int, pageID: Int, title: String) async throws -> Page
}
extension CollectivesClient: PageRenamingAPI {}

public enum PageRenamingError: Error, LocalizedError, Sendable {
    case missingPage, landingPage, unsavedDraft, unconfirmed(String)
    public var errorDescription: String? {
        switch self {
        case .missingPage: "This page is no longer available. Refresh the page list before renaming."
        case .landingPage: "The landing page follows the collective name and cannot be renamed here."
        case .unsavedDraft: "Save or export the current draft before renaming a page."
        case .unconfirmed(let reason): "Rename was not confirmed. Refresh the page list before trying again. \(reason)"
        }
    }
}

public struct RenamedPage: Sendable {
    public let page: Page
    public let snapshot: AccountSnapshot
    public let warnings: [String]
}

public enum PageRenamer {
    public static func rename(title input: String, pageID: Int, collectiveID: Int,
                              snapshot: AccountSnapshot, api: any PageRenamingAPI) async throws -> RenamedPage {
        let title = try PageCreator.title(input)
        let before = try await api.pages(collectiveID: collectiveID)
        guard let original = before.first(where: { $0.id == pageID }) else { throw PageRenamingError.missingPage }
        guard original.parentId != 0 else { throw PageRenamingError.landingPage }
        if original.title == title { return result(page: original, pages: before, collectiveID: collectiveID, snapshot: snapshot) }
        let renamed: Page
        do {
            renamed = try await api.renamePage(collectiveID: collectiveID, pageID: pageID, title: title)
        } catch {
            if let known = error as? CollectivesError,
               case .http(let code) = known, (400..<500).contains(code), code != 408 { throw error }
            if let refreshed = try? await api.pages(collectiveID: collectiveID),
               let recovered = refreshed.first(where: { $0.id == pageID && $0.title == title }) {
                return result(page: recovered, pages: refreshed, collectiveID: collectiveID, snapshot: snapshot)
            }
            throw PageRenamingError.unconfirmed(error.localizedDescription)
        }
        guard renamed.id == pageID else { throw PageRenamingError.unconfirmed("Unexpected page identifier.") }
        if let refreshed = try? await api.pages(collectiveID: collectiveID),
           let page = refreshed.first(where: { $0.id == pageID }) {
            return result(page: page, pages: refreshed, collectiveID: collectiveID, snapshot: snapshot)
        }
        let remapped = before.map { page -> Page in
            if page.id == pageID { return renamed }
            guard !original.filePath.isEmpty, original.filePath != renamed.filePath,
                  PageTree.path(to: page.id, pages: before).contains(where: { $0.id == pageID }),
                  page.filePath == original.filePath || page.filePath.hasPrefix(original.filePath + "/") else { return page }
            let path = renamed.filePath + page.filePath.dropFirst(original.filePath.count)
            return Page(id: page.id, title: page.title, fileName: page.fileName, filePath: path,
                collectivePath: page.collectivePath, parentId: page.parentId, emoji: page.emoji,
                timestamp: page.timestamp, lastUserDisplayName: page.lastUserDisplayName)
        }
        return result(page: renamed, pages: remapped, collectiveID: collectiveID, snapshot: snapshot,
            warnings: ["Rename confirmed. Refresh the page list when connected to check for other server changes."])
    }

    private static func result(page: Page, pages: [Page], collectiveID: Int, snapshot: AccountSnapshot,
                               warnings: [String] = []) -> RenamedPage {
        var next = snapshot
        next.replacePages(pages, collectiveID: collectiveID)
        return RenamedPage(page: page, snapshot: next, warnings: warnings)
    }
}
