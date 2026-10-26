import Foundation

/// Navigation uses presentation text, never Markdown source or link destinations.
public struct MarkdownReadingNavigation: Sendable {
    public struct Heading: Identifiable, Equatable, Sendable {
        public let id: String
        public let level: Int
        public let title: String
    }

    public struct SearchResult: Identifiable, Equatable, Sendable {
        public let blockIndex: Int
        public let snippet: String
        public let occurrences: Int
        public var id: Int { blockIndex }
    }

    public let headings: [Heading]
    private let text: [String]

    public init(content: MarkdownContent) {
        headings = Self.headings(in: content.blocks)
        text = content.blocks.map(Self.text)
    }

    public static func blockAnchor(_ index: Int) -> String { "reading-block:\(index)" }

    /// One result per rendered block, with a total for repeated matches in that block.
    public func search(_ query: String) -> [SearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return text.enumerated().compactMap { index, text in
            var searchStart = text.startIndex
            var count = 0
            var first: Range<String.Index>?
            while searchStart < text.endIndex,
                  let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                if first == nil { first = range }
                count += 1
                searchStart = range.upperBound
            }
            guard let first else { return nil }
            let start = text.index(first.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(first.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = (start > text.startIndex ? "…" : "")
                + text[start..<end].replacingOccurrences(of: "\n", with: " ")
                + (end < text.endIndex ? "…" : "")
            return SearchResult(blockIndex: index, snippet: snippet, occurrences: count)
        }
    }

    private static func headings(in blocks: [MarkdownBlock]) -> [Heading] {
        blocks.flatMap { block -> [Heading] in
            switch block {
            case .heading(let level, let anchor, let content): return [Heading(id: anchor, level: level, title: inlineText(content))]
            case .quote(let children): return headings(in: children)
            case .list(_, let items): return items.flatMap { headings(in: $0.blocks) }
            default: return []
            }
        }
    }

    private static func text(_ block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let content), .heading(_, _, let content): return inlineText(content)
        case .code(_, let source), .unsupported(let source): return source
        case .quote(let blocks): return blocks.map(text).joined(separator: "\n")
        case .list(_, let items): return items.flatMap(\.blocks).map(text).joined(separator: "\n")
        case .table(let header, let rows): return ([header] + rows).flatMap { $0 }.map(inlineText).joined(separator: "\n")
        case .thematicBreak: return ""
        }
    }

    private static func inlineText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text), .code(let text): return text
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, let children): return inlineText(children)
            case .image(_, let alt): return alt
            case .softBreak: return " "
            case .lineBreak: return "\n"
            }
        }.joined()
    }
}
