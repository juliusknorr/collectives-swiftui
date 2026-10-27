import Testing
@testable import CollectivesCore

private func searchPage(_ id: Int, _ title: String, parent: Int = 0) -> Page {
    Page(id: id, title: title, fileName: "\(title).md", filePath: "", collectivePath: nil, parentId: parent)
}

private func searchSnapshot() -> AccountSnapshot {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 1, name: "Engineering"), Collective(id: 2, name: "Design")]
    snapshot.pages = [
        "1": [searchPage(10, "Engineering"), searchPage(11, "Guides", parent: 10),
              searchPage(12, "Café setup", parent: 11)],
        "2": [searchPage(20, "Design"), searchPage(21, "Setup checklist", parent: 20)]
    ]
    return snapshot
}

@Test func quickSearchFindsPagesAcrossCollectivesWithBreadcrumbs() {
    let results = PageQuickSearch.results(in: searchSnapshot(), query: "setup")
    #expect(results.map(\.id) == [21, 12])
    #expect(results[0].collectiveID == 2)
    #expect(results[0].subtitle == "Design")
    #expect(results[1].collectiveName == "Engineering")
    #expect(results[1].ancestors.map(\.id) == [10, 11])
    #expect(results[1].subtitle == "Engineering › Guides")
}

@Test func quickSearchUsesCurrentMetadataBeforeCachedPagesAndIncludesDownloadFallback() {
    var snapshot = searchSnapshot()
    snapshot.documents = [
        "12": CachedDocument(page: searchPage(12, "Old title"), collectiveID: 2, markdown: "", etag: nil),
        "30": CachedDocument(page: searchPage(30, "Offline notes", parent: 11), collectiveID: 1, markdown: "", etag: nil)
    ]
    let results = PageQuickSearch.results(in: snapshot, query: "")
    #expect(results.filter { $0.id == 12 }.count == 1)
    #expect(results.first { $0.id == 12 }?.page.title == "Café setup")
    #expect(results.first { $0.id == 12 }?.collectiveID == 1)
    #expect(results.first { $0.id == 30 }?.subtitle == "Engineering › Guides")
    #expect(PageQuickSearch.results(in: snapshot, query: "Old title").isEmpty)
}

@Test func quickSearchExcludesUnknownCollectivesAndDoesNotSearchDocumentBodies() {
    var snapshot = searchSnapshot()
    snapshot.pages["99"] = [searchPage(99, "Inaccessible")]
    snapshot.documents = [
        "98": CachedDocument(page: searchPage(98, "Inaccessible cached"), collectiveID: 99, markdown: "", etag: nil),
        "12": CachedDocument(page: searchPage(12, "Café setup"), collectiveID: 1, markdown: "Secret body text", etag: nil)
    ]
    #expect(PageQuickSearch.results(in: snapshot, query: "Inaccessible").isEmpty)
    #expect(PageQuickSearch.results(in: snapshot, query: "Secret").isEmpty)
    #expect(Set(PageQuickSearch.results(in: snapshot, query: "").map(\.collectiveID)) == [1, 2])
}

@Test func quickSearchMatchesAllTokensAcrossTitleCollectiveAndAncestorsIgnoringAccents() {
    let snapshot = searchSnapshot()
    #expect(PageQuickSearch.results(in: snapshot, query: "  CAFE\tengineering\nGUIDES ").map(\.id) == [12])
    #expect(PageQuickSearch.results(in: snapshot, query: "cafe design").isEmpty)
    #expect(PageQuickSearch.results(in: snapshot, query: "unmatched").isEmpty)
    #expect(PageQuickSearch.results(in: AccountSnapshot(), query: "").isEmpty)
}

@Test func quickSearchRanksTitleMatchesAboveContextAndUsesRecentsForEmptyQueries() {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 1, name: "Setup")]
    snapshot.pages["1"] = [
        searchPage(1, "Setup"), searchPage(2, "Setup guide", parent: 1),
        searchPage(3, "A setup checklist", parent: 1), searchPage(4, "A context match", parent: 1)
    ]
    #expect(PageQuickSearch.results(in: snapshot, query: "setup", recentPageIDs: [4]).map(\.id) == [1, 2, 3, 4])
    #expect(PageQuickSearch.results(in: snapshot, query: " \n").map(\.id) == [4, 3, 1, 2])
    #expect(PageQuickSearch.results(in: snapshot, query: "", recentPageIDs: [99, 2, 2, 4]).map(\.id) == [2, 4, 3, 1])
}

@Test func quickSearchOrderingAndCycleBreadcrumbsAreDeterministic() {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 2, name: "Zulu"), Collective(id: 1, name: "Alpha")]
    snapshot.pages = [
        "1": [searchPage(1, "Same", parent: 2), searchPage(2, "Same", parent: 1)],
        "2": [searchPage(3, "Same"), searchPage(4, "Page 10"), searchPage(5, "Page 2")]
    ]
    let results = PageQuickSearch.results(in: snapshot, query: "")
    #expect(results.map(\.id) == [5, 4, 1, 2, 3])
    #expect(results.first { $0.id == 1 }?.ancestors.isEmpty == true)
    #expect(results.first { $0.id == 2 }?.ancestors.map(\.id) == [1])
    snapshot.collectives.reverse()
    snapshot.pages["1"]?.reverse()
    #expect(PageQuickSearch.results(in: snapshot, query: "") == results)
}
