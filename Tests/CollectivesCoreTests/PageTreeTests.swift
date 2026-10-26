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
