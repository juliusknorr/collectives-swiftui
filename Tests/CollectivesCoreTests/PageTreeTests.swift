import Testing
@testable import CollectivesCore

private func treePage(_ id: Int, _ title: String, parent: Int = 0) -> Page {
    Page(id: id, title: title, fileName: "\(title).md", filePath: "", collectivePath: nil, parentId: parent)
}

@Test func pageTreePreservesHierarchyAndSortsSiblings() {
    let pages = [
        treePage(3, "beta"), treePage(2, "Alpha"), treePage(1, "alpha"),
        treePage(5, "Zebra", parent: 1), treePage(4, "apple", parent: 1),
        treePage(6, "Nested", parent: 4)
    ]
    let roots = PageTree.build(pages: pages)
    #expect(roots.map(\.id) == [1, 2, 3])
    #expect(roots[0].children?.map(\.id) == [4, 5])
    #expect(roots[0].children?[0].children?.map(\.id) == [6])
    #expect(roots[0].children?[1].children == nil)
    #expect(roots[1].children == nil)
    #expect(PageTree.path(to: 6, pages: pages).map(\.id) == [1, 4, 6])
}

@Test func pageTreePromotesOrphansAndKeepsFirstDuplicate() {
    let pages = [
        treePage(1, "Original", parent: 99), treePage(1, "Duplicate"),
        treePage(2, "Child", parent: 1), treePage(3, "Self", parent: 3)
    ]
    let roots = PageTree.build(pages: pages)
    #expect(roots.map(\.id) == [1, 3])
    #expect(roots[0].page.title == "Original")
    #expect(roots[0].children?.map(\.id) == [2])
    #expect(PageTree.path(to: 2, pages: pages).map(\.id) == [1, 2])
    #expect(PageTree.path(to: 3, pages: pages).map(\.id) == [3])
    #expect(PageTree.path(to: 99, pages: pages).isEmpty)
}

@Test func pageTreeRepairsCyclesWithoutLosingPages() {
    let pages = [
        treePage(4, "Branch", parent: 3), treePage(3, "Three", parent: 2),
        treePage(2, "Two", parent: 1), treePage(1, "One", parent: 3),
        treePage(5, "Five", parent: 6), treePage(6, "Six", parent: 5)
    ]
    let roots = PageTree.build(pages: pages)
    #expect(roots.map(\.id) == [5, 1])
    #expect(PageTree.path(to: 4, pages: pages).map(\.id) == [1, 2, 3, 4])
    #expect(PageTree.path(to: 6, pages: pages).map(\.id) == [5, 6])
    #expect(PageTree.build(pages: Array(pages.reversed())) == roots)

    func allIDs(_ nodes: [PageNode]) -> [Int] {
        nodes.flatMap { [$0.id] + allIDs($0.children ?? []) }
    }
    #expect(allIDs(roots).sorted() == [1, 2, 3, 4, 5, 6])
}

@Test func emptyPageTreeHasNoRootsOrBreadcrumbs() {
    #expect(PageTree.build(pages: []).isEmpty)
    #expect(PageTree.path(to: 1, pages: []).isEmpty)
    #expect(PageNode(page: treePage(1, "Leaf"), children: []).children == nil)
}

@Test func nestedAncestorsSkipTheLandingPage() {
    func page(_ id: Int, parent: Int) -> Page {
        Page(id: id, title: "P\(id)", fileName: "P\(id).md", filePath: "", collectivePath: "Collectives/Team", parentId: parent)
    }
    let pages = [page(1, parent: 0), page(2, parent: 1), page(3, parent: 2), page(4, parent: 3)]
    #expect(PageTree.nestedAncestors(of: 1, pages: pages).isEmpty)
    #expect(PageTree.nestedAncestors(of: 2, pages: pages).isEmpty)
    #expect(PageTree.nestedAncestors(of: 4, pages: pages).map(\.id) == [2, 3])
}

@Test func pageTreeFlattensDepthFirstWithAncestors() {
    let pages = [
        treePage(1, "Landing"), treePage(3, "beta", parent: 1), treePage(2, "Alpha", parent: 1),
        treePage(4, "Nested", parent: 2), treePage(5, "Deep", parent: 4)
    ]
    let entries = PageTree.flattened(pages: pages)
    #expect(entries.map(\.id) == [1, 2, 4, 5, 3])
    #expect(entries.map(\.depth) == [0, 1, 2, 3, 1])
    #expect(entries[3].ancestors.map(\.id) == [1, 2, 4])
    #expect(PageTree.flattened(pages: []).isEmpty)
}

@Test func pageTreeFilterMatchesTitlesOnlyAndKeepsOrder() {
    let entries = PageTree.flattened(pages: [
        treePage(1, "Landing"), treePage(2, "Café notes", parent: 1),
        treePage(3, "Meetings", parent: 1), treePage(4, "cafe plans", parent: 3)
    ])
    #expect(PageTree.filter(entries, title: "  ").map(\.id) == [1, 2, 3, 4])
    #expect(PageTree.filter(entries, title: "CAFE").map(\.id) == [2, 4])
    #expect(PageTree.filter(entries, title: "Meetings").map(\.id) == [3])
    #expect(PageTree.filter(entries, title: "missing").isEmpty)
    #expect(PageTree.filter(entries, title: "cafe").last?.ancestors.map(\.title) == ["Landing", "Meetings"])
}
