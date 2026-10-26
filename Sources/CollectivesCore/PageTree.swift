import Foundation

public struct PageNode: Identifiable, Hashable, Sendable {
    public let page: Page
    public let children: [PageNode]?
    public var id: Int { page.id }

    public init(page: Page, children: [PageNode]? = nil) {
        self.page = page
        self.children = children?.isEmpty == false ? children : nil
    }
}

public enum PageTree {
    public static func build(pages: [Page]) -> [PageNode] {
        let (uniquePages, parents) = hierarchy(pages)
        let children = Dictionary(grouping: uniquePages.values, by: { parents[$0.id] })

        func nodes(parent: Int?) -> [PageNode] {
            (children[parent] ?? []).sorted(by: precedes).map { page in
                PageNode(page: page, children: nodes(parent: page.id))
            }
        }

        return nodes(parent: nil)
    }

    public static func path(to id: Int, pages: [Page]) -> [Page] {
        let (uniquePages, parents) = hierarchy(pages)
        var result: [Page] = []
        var current: Int? = id
        while let pageID = current, let page = uniquePages[pageID] {
            result.append(page)
            current = parents[pageID]
        }
        return result.reversed()
    }

    private static func precedes(_ left: Page, _ right: Page) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let comparison = left.title.lowercased(with: locale).compare(
            right.title.lowercased(with: locale), options: .numeric, locale: locale
        )
        return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
    }

    private static func hierarchy(_ pages: [Page]) -> ([Int: Page], [Int: Int]) {
        var uniquePages: [Int: Page] = [:]
        for page in pages where uniquePages[page.id] == nil {
            uniquePages[page.id] = page
        }

        var parents: [Int: Int] = [:]
        for page in uniquePages.values {
            if page.parentId != 0, page.parentId != page.id, uniquePages[page.parentId] != nil {
                parents[page.id] = page.parentId
            }
        }

        var visited: Set<Int> = []
        for id in uniquePages.keys.sorted() where !visited.contains(id) {
            var chain: [Int] = []
            var positions: [Int: Int] = [:]
            var current: Int? = id
            while let pageID = current, !visited.contains(pageID) {
                if let start = positions[pageID] {
                    // A stable root keeps a malformed cycle visible regardless of response order.
                    if let root = chain[start...].min() { parents.removeValue(forKey: root) }
                    break
                }
                positions[pageID] = chain.count
                chain.append(pageID)
                current = parents[pageID]
            }
            visited.formUnion(chain)
        }

        return (uniquePages, parents)
    }
}
