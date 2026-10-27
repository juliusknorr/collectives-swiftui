import Foundation

public struct PageQuickSearchResult: Identifiable, Equatable, Sendable {
    public let page: Page
    public let collectiveID: Int
    public let collectiveName: String
    public let ancestors: [Page]
    public var id: Int { page.id }
    public var subtitle: String {
        ([collectiveName] + ancestors.filter { $0.parentId != 0 }.map(\.title))
            .joined(separator: " › ")
    }
}

public enum PageQuickSearch {
    public static func results(
        in snapshot: AccountSnapshot, query: String, recentPageIDs: [Int] = []
    ) -> [PageQuickSearchResult] {
        let collectives = snapshot.collectives.sorted { $0.id < $1.id }
        var pagesByCollective: [Int: [Page]] = [:]
        var indexedIDs: Set<Int> = []
        for collective in collectives {
            for page in snapshot.pages[String(collective.id)] ?? [] where indexedIDs.insert(page.id).inserted {
                pagesByCollective[collective.id, default: []].append(page)
            }
        }
        let collectiveIDs = Set(collectives.map(\.id))
        for key in snapshot.documents.keys.sorted() {
            guard let document = snapshot.documents[key], collectiveIDs.contains(document.collectiveID),
                  indexedIDs.insert(document.page.id).inserted else { continue }
            pagesByCollective[document.collectiveID, default: []].append(document.page)
        }

        let tokens = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let phrase = tokens.joined(separator: " ")
        var matches: [(result: PageQuickSearchResult, rank: Int)] = []
        for collective in collectives {
            let pages = pagesByCollective[collective.id] ?? []
            var pending = PageTree.build(pages: pages).map { (node: $0, ancestors: [Page]()) }
            while let (node, ancestors) = pending.popLast() {
                let page = node.page
                pending.append(contentsOf: (node.children ?? []).map { ($0, ancestors + [page]) })
                let title = normalized(page.title)
                let context = normalized(([page.title, collective.name] + ancestors.map(\.title)).joined(separator: " "))
                guard tokens.allSatisfy({ context.contains($0) }) else { continue }
                let rank: Int
                if title == phrase { rank = 0 }
                else if title.hasPrefix(phrase) { rank = 1 }
                else if tokens.allSatisfy({ title.contains($0) }) { rank = 2 }
                else { rank = 3 }
                matches.append((PageQuickSearchResult(
                    page: page, collectiveID: collective.id, collectiveName: collective.name, ancestors: ancestors
                ), rank))
            }
        }

        var recentRanks: [Int: Int] = [:]
        for (index, id) in recentPageIDs.enumerated() where recentRanks[id] == nil {
            recentRanks[id] = index
        }
        return matches.sorted { left, right in
            if tokens.isEmpty {
                let leftRecent = recentRanks[left.result.id] ?? Int.max
                let rightRecent = recentRanks[right.result.id] ?? Int.max
                if leftRecent != rightRecent { return leftRecent < rightRecent }
            } else if left.rank != right.rank {
                return left.rank < right.rank
            }
            let titleOrder = compare(left.result.page.title, right.result.page.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let collectiveOrder = compare(left.result.collectiveName, right.result.collectiveName)
            if collectiveOrder != .orderedSame { return collectiveOrder == .orderedAscending }
            return left.result.id < right.result.id
        }.map(\.result)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func compare(_ left: String, _ right: String) -> ComparisonResult {
        normalized(left).compare(normalized(right), options: .numeric, locale: Locale(identifier: "en_US_POSIX"))
    }
}
