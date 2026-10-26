import Testing
@testable import CollectivesCore

@Test func readingOutlineIncludesNestedHeadingsWithParserAnchors() {
    let content = MarkdownContent(source: "# Title\n\n> ## **Details**\n\n## Details")
    let navigation = MarkdownReadingNavigation(content: content)
    #expect(navigation.headings.map(\.title) == ["Title", "Details", "Details"])
    #expect(navigation.headings.map(\.id) == ["title", "details", "details-1"])
    #expect(navigation.headings.map(\.level) == [1, 2, 2])
}

@Test func readerFindSearchesRenderedTextInTablesCodeAndNestedLists() {
    let content = MarkdownContent(source: """
    **Café** and CAFE

    - A café in a list

    | Location | Value |
    | --- | --- |
    | Café | 1 |

    ```text
    café
    ```
    """)
    let results = MarkdownReadingNavigation(content: content).search("cafe")
    #expect(results.map(\.blockIndex) == [0, 1, 2, 3])
    #expect(results.map(\.occurrences) == [2, 1, 1, 1])
    #expect(results[0].snippet == "Café and CAFE")
}

@Test func readerFindIgnoresDestinationsAndMarkdownSyntax() {
    let navigation = MarkdownReadingNavigation(content: MarkdownContent(source: "[Visible](https://hidden.example.com) **bold** ![Caption](secret.png)"))
    #expect(navigation.search("hidden").isEmpty)
    #expect(navigation.search("secret").isEmpty)
    #expect(navigation.search("**").isEmpty)
    #expect(navigation.search("  ").isEmpty)
    #expect(navigation.search("caption").count == 1)
    #expect(MarkdownReadingNavigation.blockAnchor(2) == "reading-block:2")
}

@Test func readerFindSnippetsCenterTheFirstMatch() {
    let navigation = MarkdownReadingNavigation(content: MarkdownContent(source: String(repeating: "before ", count: 30) + "Needle" + String(repeating: " after", count: 40)))
    let result = navigation.search("needle").first
    #expect(result?.snippet.hasPrefix("…") == true)
    #expect(result?.snippet.hasSuffix("…") == true)
    #expect(result?.snippet.contains("Needle") == true)
    #expect(result?.occurrences == 1)
}
