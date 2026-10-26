import Foundation
import Testing
@testable import CollectivesCore

@Test func recentPagesStayUniqueAndBounded() {
    var state = PageLibraryState()
    for id in 1...25 { state.visit(pageID: id, collectiveID: 3) }
    state.visit(pageID: 20, collectiveID: 4)
    #expect(state.recentPageIDs.count == 20)
    #expect(state.recentPageIDs.first == 20)
    #expect(state.recentPageIDs.filter { $0 == 20 }.count == 1)
    #expect(state.collectiveID == 4 && state.pageID == 20)
}

@Test @MainActor func navigationAndFavoritesPersistPerAccountAndCleanUpIndependently() throws {
    let suite = "LibraryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = UUID(); let second = UUID()
    let preferences = LibraryPreferences(defaults: defaults)
    var state = PageLibraryState()
    state.visit(pageID: 7, collectiveID: 2); state.toggleFavorite(7)
    preferences.save(state, accountID: first)
    state.toggleFavorite(7); state.toggleFavorite(8)
    preferences.save(state, accountID: second)
    preferences.lastAccountID = second
    defaults.set("2,7", forKey: "outline.\(first.uuidString).2")
    defaults.set(3, forKey: "readingPosition.\(first.uuidString).7")
    defaults.set(5, forKey: "readingPosition.\(second.uuidString).7")
    let restored = LibraryPreferences(defaults: defaults)
    #expect(restored.lastAccountID == second)
    #expect(restored.load(accountID: first).favoritePageIDs == [7])
    #expect(restored.load(accountID: second).favoritePageIDs == [8])
    #expect(restored.load(accountID: second).pageID == 7)
    restored.remove(accountID: first)
    #expect(restored.load(accountID: first) == PageLibraryState())
    #expect(defaults.object(forKey: "readingPosition.\(first.uuidString).7") == nil)
    #expect(defaults.object(forKey: "outline.\(first.uuidString).2") == nil)
    #expect(restored.load(accountID: second).favoritePageIDs == [8])
    #expect(defaults.integer(forKey: "readingPosition.\(second.uuidString).7") == 5)
    #expect(restored.lastAccountID == second)
}
