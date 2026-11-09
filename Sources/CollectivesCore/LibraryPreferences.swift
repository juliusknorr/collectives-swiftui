import Foundation

public enum LaunchPage: Codable, Equatable, Hashable, Sendable {
    case home
    case page(Int)
}

public struct PageLibraryState: Codable, Equatable, Sendable {
    public var collectiveID: Int?
    /// Nil opens the last opened page.
    public var launchPage: LaunchPage?
    public var pageID: Int?
    public var recentPageIDs: [Int] = []
    public var favoritePageIDs: [Int] = []
    public init() {}
    public mutating func visit(pageID: Int, collectiveID: Int) {
        self.pageID = pageID; self.collectiveID = collectiveID
        recentPageIDs.removeAll { $0 == pageID }
        recentPageIDs.insert(pageID, at: 0)
        recentPageIDs = Array(recentPageIDs.prefix(20))
    }
    public mutating func toggleFavorite(_ pageID: Int) {
        if favoritePageIDs.contains(pageID) { favoritePageIDs.removeAll { $0 == pageID } }
        else { favoritePageIDs.append(pageID) }
    }
    public mutating func toggleLaunchPage(_ pageID: Int) {
        launchPage = launchPage == .page(pageID) ? nil : .page(pageID)
    }
}

extension PageLibraryState {
    /// An unknown launch page from a newer version falls back to last opened instead of dropping favorites and recents.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collectiveID = try container.decodeIfPresent(Int.self, forKey: .collectiveID)
        launchPage = try? container.decodeIfPresent(LaunchPage.self, forKey: .launchPage)
        pageID = try container.decodeIfPresent(Int.self, forKey: .pageID)
        recentPageIDs = try container.decodeIfPresent([Int].self, forKey: .recentPageIDs) ?? []
        favoritePageIDs = try container.decodeIfPresent([Int].self, forKey: .favoritePageIDs) ?? []
    }
}

@MainActor
public final class LibraryPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var lastAccountID: UUID? {
        get { defaults.string(forKey: "lastAccountID").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "lastAccountID") }
    }
    public func load(accountID: UUID) -> PageLibraryState {
        guard let data = defaults.data(forKey: key(accountID)),
              let state = try? JSONDecoder().decode(PageLibraryState.self, from: data) else { return PageLibraryState() }
        return state
    }
    public func save(_ state: PageLibraryState, accountID: UUID) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key(accountID)) }
    }
    public func remove(accountID: UUID) {
        defaults.removeObject(forKey: key(accountID))
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("outline.\(accountID.uuidString).") || key.hasPrefix("readingPosition.\(accountID.uuidString).") {
            defaults.removeObject(forKey: key)
        }
        if lastAccountID == accountID { lastAccountID = nil }
    }
    private func key(_ id: UUID) -> String { "pageLibrary.\(id.uuidString)" }
}
