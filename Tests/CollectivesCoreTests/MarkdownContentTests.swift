import Testing
@testable import CollectivesCore

@Test func markdownRendersInlineFormattingAndPreservesLiteralPunctuation() {
    let content = MarkdownContent(source: "Hello *world*, **bold**, ~~old~~ and `code` -- \"quoted\".")
    #expect(content.blocks == [.paragraph([
        .text("Hello "), .emphasis([.text("world")]), .text(", "),
        .strong([.text("bold")]), .text(", "), .strikethrough([.text("old")]),
        .text(" and "), .code("code"), .text(" -- \"quoted\".")
    ])])
}

@Test func markdownPreservesOrderedStartsNestedListsAndTaskStates() {
    let content = MarkdownContent(source: """
    3. Parent
       - [x] Done
       - [ ] Pending
    4. Next
    """)
    #expect(content.blocks == [.list(start: 3, items: [
        MarkdownListItem(blocks: [
            .paragraph([.text("Parent")]),
            .list(start: nil, items: [
                MarkdownListItem(checked: true, blocks: [.paragraph([.text("Done")])]),
                MarkdownListItem(checked: false, blocks: [.paragraph([.text("Pending")])])
            ])
        ]),
        MarkdownListItem(blocks: [.paragraph([.text("Next")])])
    ])])
}

@Test func markdownParsesTablesCodeAndQuotes() {
    let content = MarkdownContent(source: """
    | Name | Status |
    | --- | --- |
    | **App** | Ready |

    ```swift
    let value = 1
    ```

    > A quote

    ---
    """)
    #expect(content.blocks == [
        .table(header: [[.text("Name")], [.text("Status")]], rows: [
            [[.strong([.text("App")])], [.text("Ready")]]
        ]),
        .code(language: "swift", source: "let value = 1\n"),
        .quote([.paragraph([.text("A quote")])]),
        .thematicBreak
    ])
}

@Test func markdownPreservesLinksImagesAndBreaks() {
    let content = MarkdownContent(source: """
    [Page](../Other.md#intro) ![An *image*](./assets/picture.png)
    next line\u{0020}\u{0020}
    hard break
    """)
    #expect(content.blocks == [.paragraph([
        .link(destination: "../Other.md#intro", children: [.text("Page")]), .text(" "),
        .image(source: "./assets/picture.png", alt: "An image"), .softBreak,
        .text("next line"), .lineBreak, .text("hard break")
    ])])
}

@Test func markdownHeadingAnchorsAreStableAndUnique() {
    let content = MarkdownContent(source: """
    # Hello, **World**!
    ## Hello, World!
    ### Hello World-1
    # Über Café
    """)
    #expect(content.blocks == [
        .heading(level: 1, anchor: "hello-world", content: [.text("Hello, "), .strong([.text("World")]), .text("!")]),
        .heading(level: 2, anchor: "hello-world-1", content: [.text("Hello, World!")]),
        .heading(level: 3, anchor: "hello-world-1-1", content: [.text("Hello World-1")]),
        .heading(level: 1, anchor: "über-café", content: [.text("Über Café")])
    ])
}

@Test func markdownHTMLRemainsInertSource() {
    let content = MarkdownContent(source: """
    <script>alert('unsafe')</script>

    Text <span onclick="run()">visible</span>.
    """)
    #expect(content.blocks == [
        .unsupported("<script>alert('unsafe')</script>\n"),
        .paragraph([.text("Text "), .text("<span onclick=\"run()\">"), .text("visible"), .text("</span>"), .text(".")])
    ])
    #expect(MarkdownContent(source: "").blocks.isEmpty)
}
