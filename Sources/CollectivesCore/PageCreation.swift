import Foundation

public protocol PageCreationAPI: Sendable {
    func pages(collectiveID: Int) async throws -> [Page]
    func createPage(collectiveID: Int, parentID: Int, title: String) async throws -> Page
    func download(page: Page) async throws -> RemoteDocument
}

extension CollectivesClient: PageCreationAPI {}

public enum PageCreationError: Error, LocalizedError, Sendable {
    case invalidTitle, missingParent, unsavedDraft, unconfirmed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidTitle: "Enter a page title without line breaks or slashes."
        case .unsavedDraft: "Save or export the current draft before creating a page."
        case .missingParent: "The parent page is no longer available. Refresh the page list and choose another parent."
        case .unconfirmed(let reason): "Creation was not confirmed. Refresh the page list before trying again to avoid creating a duplicate. \(reason)"
        }
    }
}

public struct CreatedPage: Sendable {
    public let page: Page
    public let snapshot: AccountSnapshot
    public let warnings: [String]
}

public enum PageCreator {
    public static func title(_ input: String) throws -> String {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != ".", title != "..",
              !title.contains("/"), !title.contains("\\"),
              !title.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) }) else {
            throw PageCreationError.invalidTitle
        }
        return title
    }

    public static func create(title input: String, parentID: Int, collectiveID: Int,
                              snapshot: AccountSnapshot, api: any PageCreationAPI) async throws -> CreatedPage {
        let title = try title(input)
        let before = try await api.pages(collectiveID: collectiveID)
        guard before.contains(where: { $0.id == parentID }) else { throw PageCreationError.missingParent }
        let created: Page
        do { created = try await api.createPage(collectiveID: collectiveID, parentID: parentID, title: title) }
        catch let error as CollectivesError {
            if case .http(let code) = error, (400..<500).contains(code), code != 408 { throw error }
            throw PageCreationError.unconfirmed(error.localizedDescription)
        } catch { throw PageCreationError.unconfirmed(error.localizedDescription) }
        var warnings: [String] = []
        var pages = before.filter { $0.id != created.id } + [created]
        do {
            pages = try await api.pages(collectiveID: collectiveID)
            if !pages.contains(where: { $0.id == created.id }) { pages.append(created) }
        } catch { warnings.append("Refresh the page list to update parent paths. \(error.localizedDescription)") }
        var next = snapshot
        next.pages[String(collectiveID)] = pages
        for page in pages {
            if var cached = next.documents[String(page.id)], cached.collectiveID == collectiveID {
                cached.page = page
                next.documents[String(page.id)] = cached
            }
        }
        let page = pages.first { $0.id == created.id } ?? created
        if next.documents[String(page.id)] == nil {
            do {
                let remote = try await api.download(page: page)
                next.documents[String(page.id)] = CachedDocument(page: page, collectiveID: collectiveID,
                    markdown: remote.markdown, etag: remote.etag)
            } catch { warnings.append("The new page is not downloaded yet. Open it again when connected. \(error.localizedDescription)") }
        }
        return CreatedPage(page: page, snapshot: next, warnings: warnings)
    }
}
