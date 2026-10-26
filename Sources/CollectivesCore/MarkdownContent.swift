import Foundation
import Markdown

public indirect enum MarkdownInline: Hashable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(destination: String, children: [MarkdownInline])
    case image(source: String, alt: String)
    case softBreak
    case lineBreak
}

public indirect enum MarkdownBlock: Hashable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, anchor: String, content: [MarkdownInline])
    case code(language: String?, source: String)
    case quote([MarkdownBlock])
    case list(start: Int?, items: [MarkdownListItem])
    case table(header: [[MarkdownInline]], rows: [[[MarkdownInline]]])
    case thematicBreak
    case unsupported(String)
}

public struct MarkdownListItem: Hashable, Sendable {
    public let checked: Bool?
    public let blocks: [MarkdownBlock]

    public init(checked: Bool? = nil, blocks: [MarkdownBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

/// A read-only presentation model. Saving always uses the original editor source.
public struct MarkdownContent: Hashable, Sendable {
    public let blocks: [MarkdownBlock]

    public init(source: String) {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var parser = MarkdownPresentationParser()
        blocks = document.children.map { parser.block($0) }
    }
}

private struct MarkdownPresentationParser {
    private var anchors: Set<String> = []

    mutating func block(_ markup: any Markup) -> MarkdownBlock {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(inlines(paragraph))
        case let heading as Heading:
            return .heading(level: heading.level, anchor: anchor(for: heading.plainText), content: inlines(heading))
        case let code as CodeBlock:
            return .code(language: code.language, source: code.code)
        case let quote as BlockQuote:
            return .quote(quote.children.map { block($0) })
        case let list as OrderedList:
            return .list(start: Int(list.startIndex), items: list.children.compactMap { item($0) })
        case let list as UnorderedList:
            return .list(start: nil, items: list.children.compactMap { item($0) })
        case let table as Table:
            let header = table.head.children.map { inlines($0) }
            let rows = table.body.children.map { row in row.children.map { inlines($0) } }
            return .table(header: header, rows: rows)
        case is ThematicBreak:
            return .thematicBreak
        case let html as HTMLBlock:
            return .unsupported(html.rawHTML)
        default:
            return .unsupported(markup.format())
        }
    }

    private mutating func item(_ markup: any Markup) -> MarkdownListItem? {
        guard let item = markup as? ListItem else { return nil }
        let checked: Bool?
        switch item.checkbox {
        case .checked: checked = true
        case .unchecked: checked = false
        case nil: checked = nil
        }
        return MarkdownListItem(checked: checked, blocks: item.children.map { block($0) })
    }

    private func inlines(_ markup: any Markup) -> [MarkdownInline] {
        markup.children.map { inline($0) }
    }

    private func inline(_ markup: any Markup) -> MarkdownInline {
        switch markup {
        case let text as Markdown.Text: return .text(text.string)
        case let emphasis as Emphasis: return .emphasis(inlines(emphasis))
        case let strong as Strong: return .strong(inlines(strong))
        case let strike as Strikethrough: return .strikethrough(inlines(strike))
        case let code as InlineCode: return .code(code.code)
        case let link as Markdown.Link: return .link(destination: link.destination ?? "", children: inlines(link))
        case let image as Markdown.Image: return .image(source: image.source ?? "", alt: image.plainText)
        case is SoftBreak: return .softBreak
        case is LineBreak: return .lineBreak
        case let html as InlineHTML: return .text(html.rawHTML)
        default: return .text(markup.format())
        }
    }

    private mutating func anchor(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "-_"))
        let base = title.lowercased().unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return "-" }
            return allowed.contains(scalar) ? String(scalar) : nil
        }.joined()
        var candidate = base
        var suffix = 0
        while anchors.contains(candidate) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        anchors.insert(candidate)
        return candidate
    }
}
