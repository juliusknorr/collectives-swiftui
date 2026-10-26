import Foundation

public enum MarkdownEditing {
    public enum Command: Equatable, Sendable {
        case heading, bold, italic, link, task, code
    }

    public struct Edit: Equatable, Sendable {
        public let text: String
        public let selection: NSRange
        public let replacementRange: NSRange
        public let replacement: String
    }

    /// Selection and replacement ranges use UTF-16 offsets, as native text controls do.
    public static func format(_ text: String, selection: NSRange, command: Command) -> Edit {
        let source = text as NSString
        let location = min(max(selection.location, 0), source.length)
        let range = NSRange(location: location, length: min(max(selection.length, 0), source.length - location))
        switch command {
        case .heading, .task:
            // A selection ending at the next line's beginning does not include that line.
            let probe = NSRange(location: range.location, length: max(0, range.length - 1))
            let lines = source.lineRange(for: probe)
            let original = source.substring(with: lines)
            let prefix = command == .heading ? "## " : "- [ ] "
            var parts = original.components(separatedBy: "\n")
            let contentCount = parts.last == "" && parts.count > 1 ? parts.count - 1 : parts.count
            let allPrefixed = parts.prefix(contentCount).allSatisfy { $0.hasPrefix(prefix) }
            var deltas: [(Int, Int)] = []
            var offset = lines.location
            for index in 0..<contentCount {
                let old = parts[index]
                if allPrefixed {
                    parts[index] = String(old.dropFirst(prefix.count))
                    deltas.append((offset, -prefix.utf16.count))
                } else {
                    parts[index] = prefix + old
                    deltas.append((offset, prefix.utf16.count))
                }
                offset += old.utf16.count + 1
            }
            func adjusted(_ position: Int) -> Int {
                var result = position
                for (start, delta) in deltas where start <= position {
                    result += delta < 0 ? -min(-delta, position - start) : delta
                }
                return result
            }
            let start = adjusted(range.location)
            let end = adjusted(NSMaxRange(range))
            return edit(source, replacing: lines, with: parts.joined(separator: "\n"), selection: NSRange(location: start, length: end - start))
        case .bold, .italic, .code, .link:
            let selected = source.substring(with: range)
            let placeholder = command == .link ? "link text" : command == .code ? "code" : "text"
            let content = range.length == 0 ? placeholder : selected
            let prefix: String
            let suffix: String
            switch command {
            case .bold: prefix = "**"; suffix = "**"
            case .italic: prefix = "*"; suffix = "*"
            case .link: prefix = "["; suffix = "](https://example.com)"
            case .code:
                if content.contains("\n") {
                    let longestRun = content.components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count).max() ?? 0
                    let fence = String(repeating: "`", count: max(3, longestRun + 1))
                    prefix = fence + "\n"; suffix = "\n" + fence
                }
                else {
                    let runs = content.components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count)
                    let delimiter = String(repeating: "`", count: max(1, (runs.max() ?? 0) + 1))
                    let padding = content.contains("`") ? " " : ""
                    prefix = delimiter + padding; suffix = padding + delimiter
                }
            default: fatalError("Handled above")
            }
            let nextSelection: NSRange
            if command == .link && range.length > 0 {
                nextSelection = NSRange(location: range.location + prefix.utf16.count + content.utf16.count + 2, length: "https://example.com".utf16.count)
            } else {
                nextSelection = NSRange(location: range.location + prefix.utf16.count, length: content.utf16.count)
            }
            return edit(source, replacing: range, with: prefix + content + suffix, selection: nextSelection)
        }
    }

    private static func edit(_ source: NSString, replacing range: NSRange, with replacement: String, selection: NSRange) -> Edit {
        Edit(text: source.replacingCharacters(in: range, with: replacement), selection: selection, replacementRange: range, replacement: replacement)
    }
}
