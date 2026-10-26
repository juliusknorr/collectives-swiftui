import Foundation
import Testing
@testable import CollectivesCore

@Test func markdownFormattingUsesUTF16Selection() {
    let source = "Hello 👩🏽‍💻 café"
    let selection = (source as NSString).range(of: "café")
    let edit = MarkdownEditing.format(source, selection: selection, command: .bold)
    #expect(edit.text == "Hello 👩🏽‍💻 **café**")
    #expect((edit.text as NSString).substring(with: edit.selection) == "café")
    #expect(edit.selection.location == selection.location + 2)
    #expect(edit.replacementRange == selection)
}

@Test func emptyFormattingSelectsEditablePlaceholder() {
    for command in [MarkdownEditing.Command.bold, .italic, .code, .link] {
        let edit = MarkdownEditing.format("🚀 ", selection: NSRange(location: 3, length: 0), command: command)
        let selected = (edit.text as NSString).substring(with: edit.selection)
        #expect(selected == (command == .link ? "link text" : command == .code ? "code" : "text"))
        #expect(edit.text.hasPrefix("🚀 "))
        #expect(edit.replacementRange == NSRange(location: 3, length: 0))
    }
}

@Test func linkFormattingSelectsDestinationAfterWrappingText() {
    let edit = MarkdownEditing.format("Read notes", selection: NSRange(location: 5, length: 5), command: .link)
    #expect(edit.text == "Read [notes](https://example.com)")
    #expect((edit.text as NSString).substring(with: edit.selection) == "https://example.com")
}

@Test func headingsApplyToSelectedLinesWithoutNextLine() {
    let source = "one\ntwo\nthree"
    let edit = MarkdownEditing.format(source, selection: NSRange(location: 0, length: 8), command: .heading)
    #expect(edit.text == "## one\n## two\nthree")
    #expect((edit.text as NSString).substring(with: edit.selection) == "one\n## two\n")
    let restored = MarkdownEditing.format(edit.text, selection: edit.selection, command: .heading)
    #expect(restored.text == source)
    #expect(restored.selection == NSRange(location: 0, length: 8))
}

@Test func tasksKeepCaretWithinCurrentLineAndCanToggle() {
    let source = "first\n🚀 idea\nlast"
    let caret = (source as NSString).range(of: "idea").location
    let edit = MarkdownEditing.format(source, selection: NSRange(location: caret, length: 0), command: .task)
    #expect(edit.text == "first\n- [ ] 🚀 idea\nlast")
    #expect(edit.selection == NSRange(location: caret + 6, length: 0))
    let restored = MarkdownEditing.format(edit.text, selection: edit.selection, command: .task)
    #expect(restored.text == source)
    #expect(restored.selection == NSRange(location: caret, length: 0))
}

@Test func tasksApplyAcrossLinesAndPreserveTrailingNewline() {
    let source = "alpha\nbeta\n"
    let edit = MarkdownEditing.format(source, selection: NSRange(location: 0, length: source.utf16.count), command: .task)
    #expect(edit.text == "- [ ] alpha\n- [ ] beta\n")
    #expect((edit.text as NSString).substring(with: edit.selection) == "alpha\n- [ ] beta\n")
}

@Test func codeFormattingPreservesNestedBackticksAndMultilineSource() {
    let inline = "call `name`"
    let edit = MarkdownEditing.format(inline, selection: NSRange(location: 0, length: inline.utf16.count), command: .code)
    #expect(edit.text == "`` call `name` ``")
    #expect((edit.text as NSString).substring(with: edit.selection) == inline)
    let multiline = "let x = 1\nprint(x)"
    let block = MarkdownEditing.format(multiline, selection: NSRange(location: 0, length: multiline.utf16.count), command: .code)
    #expect(block.text == "```\nlet x = 1\nprint(x)\n```")
    #expect((block.text as NSString).substring(with: block.selection) == multiline)
}

@Test func headingInEmptyDocumentLeavesCaretAfterPrefix() {
    let edit = MarkdownEditing.format("", selection: NSRange(location: 0, length: 0), command: .heading)
    #expect(edit.text == "## ")
    #expect(edit.selection == NSRange(location: 3, length: 0))
}
