import SwiftUI
import CollectivesCore
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ReadingContext {
    let account: Account?
    let documentURL: URL?
    let client: CollectivesClient?
    var searchQuery: String = ""
    func resolve(_ destination: String) -> URL? {
        guard let account, let documentURL else { return nil }
        return ReadingResources.resolve(destination: destination, documentURL: documentURL, account: account)
    }
}

struct MarkdownReader: View {
    @Binding var showingOutline: Bool
    @Binding var showingFind: Bool
    let model: AppModel
    let source: String
    let page: Page
    let account: Account?
    let pages: [Page]
    let client: CollectivesClient?
    let onOpenPage: (Page) -> Void
    @State private var content = MarkdownContent(source: "")
    @State private var loaded = false
    @State private var loadedPositionKey: String?
    @State private var query = ""
    @State private var resultIndex = 0
    @State private var restoringPosition = true
    @FocusState private var findFocused: Bool

    private var context: ReadingContext {
        ReadingContext(account: account, documentURL: try? client?.documentURL(page: page), client: client,
                       searchQuery: showingFind ? query : "")
    }
    private var navigation: MarkdownReadingNavigation { MarkdownReadingNavigation(content: content) }
    private var results: [MarkdownReadingNavigation.SearchResult] { navigation.search(query) }
    private var selectedResult: MarkdownReadingNavigation.SearchResult? {
        showingFind && results.indices.contains(resultIndex) ? results[resultIndex] : nil
    }
    private var positionKey: String { "readingPosition.\(account?.id.uuidString ?? "none").\(page.id)" }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if showingFind { findBar(proxy: proxy) }
                if showingFind { Divider() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !hasPageHeading {
                            DocumentHeader(model: model, page: page)
                        }
                        if loaded && content.blocks.isEmpty {
                            Text("This page is empty.").foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(content.blocks.enumerated()), id: \.offset) { index, block in
                                Group {
                                    if index == 0, case .heading(level: 1, let anchor, _) = block {
                                        DocumentHeader(model: model, page: page, title: navigation.headings.first?.title)
                                            .id(anchor)
                                    } else {
                                        MarkdownBlockView(block: block, context: context)
                                    }
                                }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background {
                                        if selectedResult?.blockIndex == index {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.accentColor.opacity(0.08)).padding(-6)
                                        }
                                    }
                                    .id(MarkdownReadingNavigation.blockAnchor(index))
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: ReadingBlockFrames.self,
                                                value: [index: geometry.frame(in: .named("readingViewport"))])
                                        }
                                    }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 740, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .coordinateSpace(name: "readingViewport")
                .onPreferenceChange(ReadingBlockFrames.self) { frames in
                    guard loaded, loadedPositionKey == positionKey, !restoringPosition else { return }
                    let visible = frames.filter { $0.value.maxY > 0 }.min { $0.value.minY < $1.value.minY }
                    if let visible, UserDefaults.standard.integer(forKey: positionKey) != visible.key {
                        UserDefaults.standard.set(visible.key, forKey: positionKey)
                    }
                }
            }
            .onChange(of: showingFind) { _, shown in
                findFocused = shown
            }
            .onAppear { findFocused = showingFind }
            .inspector(isPresented: $showingOutline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("On This Page").font(.headline).padding()
                    Divider()
                    if navigation.headings.isEmpty {
                        ContentUnavailableView("No Headings", systemImage: "list.bullet.indent",
                            description: Text("Add Markdown headings to give this page an outline."))
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(navigation.headings) { heading in
                                    Button {
                                        withAnimation { proxy.scrollTo(heading.id, anchor: .top) }
                                    } label: {
                                        Text(heading.title)
                                            .font(heading.level == 1 ? .headline : .body)
                                            .foregroundStyle(heading.level == 1 ? .primary : .secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                                            .padding(.vertical, 7).padding(.horizontal, 14)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AppSurface.chrome)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard let account, let target = context.resolve(url.absoluteString) else { return .discarded }
                if let fragment = target.fragment?.removingPercentEncoding,
                   ReadingResources.pageID(for: target, pages: [page], account: account) == page.id {
                    withAnimation { proxy.scrollTo(fragment, anchor: .top) }
                    return .handled
                }
                if let id = ReadingResources.pageID(for: target, pages: pages, account: account),
                   let destination = pages.first(where: { $0.id == id }) {
                    onOpenPage(destination)
                    return .handled
                }
                return .systemAction(target)
            })
            .task(id: positionKey + source) {
                restoringPosition = true
                let savedBlock = UserDefaults.standard.integer(forKey: positionKey)
                let input = source
                let parsed = await Task.detached(priority: .userInitiated) { MarkdownContent(source: input) }.value
                guard !Task.isCancelled else { return }
                content = parsed; loaded = true; loadedPositionKey = positionKey; resultIndex = 0
                // Wait for the parsed blocks to participate in layout before restoring.
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                if parsed.blocks.indices.contains(savedBlock) {
                    proxy.scrollTo(MarkdownReadingNavigation.blockAnchor(savedBlock), anchor: .top)
                }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                restoringPosition = false
            }
            .onChange(of: query) {
                resultIndex = 0
                scrollToResult(proxy)
            }
        }
    }

    private func findBar(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in page", text: $query)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    .onSubmit { moveResult(1, proxy: proxy) }
                    #if os(macOS)
                    .onExitCommand { showingFind = false; findFocused = false }
                    #endif
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(results.isEmpty ? "No results" : "\(resultIndex + 1) of \(results.count)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize()
                        .accessibilityLabel(results.isEmpty ? "No matching passages" : "Passage \(resultIndex + 1) of \(results.count)")
                }
                Button { moveResult(-1, proxy: proxy) } label: { Image(systemName: "chevron.up") }
                    .help("Previous matching passage (⇧⌘G)").accessibilityLabel("Previous matching passage")
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(results.isEmpty)
                Button { moveResult(1, proxy: proxy) } label: { Image(systemName: "chevron.down") }
                    .help("Next matching passage (⌘G)").accessibilityLabel("Next matching passage")
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(results.isEmpty)
                Button { showingFind = false; findFocused = false } label: { Image(systemName: "xmark") }
                    .help("Close find").accessibilityLabel("Close find")
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .buttonStyle(.borderless)
            if let selectedResult {
                Text(selectedResult.snippet).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).accessibilityLabel("Matching passage: \(selectedResult.snippet)")
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    private func moveResult(_ direction: Int, proxy: ScrollViewProxy) {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex + direction + results.count) % results.count
        scrollToResult(proxy)
    }

    private func scrollToResult(_ proxy: ScrollViewProxy) {
        guard let selectedResult else { return }
        withAnimation { proxy.scrollTo(MarkdownReadingNavigation.blockAnchor(selectedResult.blockIndex), anchor: .center) }
    }

    private var hasPageHeading: Bool {
        if case .heading(level: 1, _, _) = content.blocks.first { return true }
        return false
    }
}

private struct ReadingBlockFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    let context: ReadingContext
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, context: context)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let context: ReadingContext
    @ScaledMetric(relativeTo: .body) private var bodySize = 16
    var body: some View {
        switch block {
        case .paragraph(let inlines):
            MarkdownParagraph(inlines: inlines, context: context)
                .font(.system(size: bodySize)).lineSpacing(5)
        case .heading(let level, let anchor, let content):
            Text(styledInline(content, context: context))
                .font(.system(size: bodySize * headingScale(level), weight: .bold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 12 : 6)
                .accessibilityAddTraits(.isHeader)
                .id(anchor)
        case .code(let language, let source):
            CodeBlockView(language: language, source: source, searchQuery: context.searchQuery)
        case .quote(let blocks):
            MarkdownBlocks(blocks: blocks, context: context)
                .foregroundStyle(.secondary)
                .padding(.leading, 18).padding(.vertical, 6)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3) }
        case .list(let start, let items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        listMarker(item, number: start.map { $0 + index })
                            .frame(width: 24, alignment: .trailing).padding(.top, 2)
                        MarkdownBlocks(blocks: item.blocks, context: context)
                    }
                }
            }.font(.system(size: bodySize))
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, context: context)
        case .thematicBreak:
            Divider().padding(.vertical, 8)
        case .unsupported(let source):
            CodeBlockView(language: "Source", source: source, searchQuery: context.searchQuery)
        }
    }
    private func headingScale(_ level: Int) -> Double {
        switch level { case 1: 1.9; case 2: 1.5; case 3: 1.25; default: 1.05 }
    }
    @ViewBuilder private func listMarker(_ item: MarkdownListItem, number: Int?) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                .accessibilityLabel(checked ? "Completed task" : "Incomplete task")
        } else if let number { Text("\(number).").foregroundStyle(.secondary).monospacedDigit() }
        else { Text("•").foregroundStyle(.secondary) }
    }
}

private struct MarkdownParagraph: View {
    let inlines: [MarkdownInline]
    let context: ReadingContext
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if case .image(let source, let alt) = segment.first {
                    ReadingImage(source: source, alt: alt, context: context)
                } else {
                    Text(styledInline(segment, context: context)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private var segments: [[MarkdownInline]] {
        var groups: [[MarkdownInline]] = []; var pending: [MarkdownInline] = []
        for inline in inlines {
            if case .image = inline {
                if !pending.isEmpty { groups.append(pending); pending = [] }
                groups.append([inline])
            } else { pending.append(inline) }
        }
        if !pending.isEmpty { groups.append(pending) }
        return groups
    }
}

private func styledInline(_ inlines: [MarkdownInline], context: ReadingContext) -> AttributedString {
    var result = AttributedString()
    for inline in inlines {
        var value: AttributedString
        switch inline {
        case .text(let text): value = AttributedString(text)
        case .softBreak: value = AttributedString(" ")
        case .lineBreak: value = AttributedString("\n")
        case .code(let source):
            value = AttributedString(source)
            value.font = .system(.body, design: .monospaced)
            value.backgroundColor = .secondary.opacity(0.12)
        case .emphasis(let children):
            value = addingIntent(.emphasized, to: styledInline(children, context: context))
        case .strong(let children):
            value = addingIntent(.stronglyEmphasized, to: styledInline(children, context: context))
        case .strikethrough(let children):
            value = addingIntent(.strikethrough, to: styledInline(children, context: context))
        case .link(let destination, let children):
            value = styledInline(children, context: context)
            value.link = context.resolve(destination)
        case .image(_, let alt): value = AttributedString(alt)
        }
        result.append(value)
    }
    return highlighting(result, query: context.searchQuery)
}

private func addingIntent(_ intent: InlinePresentationIntent, to source: AttributedString) -> AttributedString {
    var result = source
    for run in Array(source.runs) {
        var intents = run.inlinePresentationIntent ?? []
        intents.insert(intent)
        result[run.range].inlinePresentationIntent = intents
    }
    return result
}

private func highlighting(_ source: AttributedString, query: String) -> AttributedString {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return source }
    var result = source
    let plain = String(source.characters)
    var start = plain.startIndex
    while start < plain.endIndex,
          let range = plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<plain.endIndex) {
        if let lower = AttributedString.Index(range.lowerBound, within: result),
           let upper = AttributedString.Index(range.upperBound, within: result) {
            result[lower..<upper].backgroundColor = Color.yellow.opacity(0.4)
        }
        start = range.upperBound
    }
    return result
}

private struct CodeBlockView: View {
    let language: String?
    let source: String
    var searchQuery: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "Code").font(.caption.weight(.medium))
                Spacer()
                Button("Copy Code", systemImage: "doc.on.doc") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                    #else
                    UIPasteboard.general.string = source
                    #endif
                }.labelStyle(.iconOnly).buttonStyle(.plain).help("Copy code")
            }.foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
            Divider().opacity(0.5)
            ScrollView(.horizontal) {
                Text(highlighting(AttributedString(source.trimmingCharacters(in: .newlines)), query: searchQuery))
                    .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
            }
        }
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.15), lineWidth: 1) }
    }
}

private struct MarkdownTable: View {
    let header: [[MarkdownInline]]
    let rows: [[[MarkdownInline]]]
    let context: ReadingContext
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        tableCell(cell).fontWeight(.semibold)
                    }
                }.background(.secondary.opacity(0.1))
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in tableCell(cell) }
                    }.background(.secondary.opacity(index.isMultiple(of: 2) ? 0.03 : 0.07))
                }
            }
            .font(.system(size: 14))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.2), lineWidth: 1) }
            .padding(1)
        }
    }
    private func tableCell(_ content: [MarkdownInline]) -> some View {
        Text(styledInline(content, context: context)).textSelection(.enabled)
            .frame(minWidth: 110, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReadingImage: View {
    let source: String
    let alt: String
    let context: ReadingContext
    @State private var image: Image?
    @State private var loading = false
    private static let cache = ReadingImageCache(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Collectives/Images"))
    private var url: URL? { context.resolve(source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                image.resizable().scaledToFit().frame(maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(alt.isEmpty ? "Page image" : alt)
            } else {
                HStack(spacing: 10) {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "photo").foregroundStyle(.secondary) }
                    Text(loading ? "Loading image…" : (alt.isEmpty ? "Image unavailable" : alt)).font(.callout)
                    Spacer()
                    if let url { Link("Open", destination: url).font(.caption) }
                }.padding(16).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if image != nil && !alt.isEmpty { Text(alt).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: url) {
            image = nil
            guard let url, let account = context.account, let client = context.client,
                  ReadingResources.canLoadImage(at: url, account: account) else { return }
            loading = true; defer { loading = false }
            do {
                let data: Data
                if let cached = try await Self.cache.data(for: url, accountID: account.id) { data = cached }
                else {
                    data = try await client.downloadImage(at: url)
                    try? await Self.cache.store(data, for: url, accountID: account.id)
                }
                try Task.checkCancellation()
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048
                   ] as CFDictionary) {
                    image = Image(decorative: thumbnail, scale: 1)
                }
            } catch { image = nil }
        }
    }
}
