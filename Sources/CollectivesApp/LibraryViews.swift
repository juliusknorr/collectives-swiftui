import SwiftUI
import CollectivesCore

struct DocumentHeader: View {
    @Bindable var model: AppModel
    let page: Page
    @State private var showIcons = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button { showIcons = true } label: {
                    if let emoji = page.emoji, !emoji.isEmpty {
                        Text(emoji).font(.system(size: 34)).accessibilityHidden(true)
                    } else {
                        Image(systemName: "doc.text").font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain).help("Change page icon")
                .accessibilityLabel("Change page icon").disabled(model.busy || !model.canEdit)
                .popover(isPresented: $showIcons) {
                    PageEmojiPicker(current: page.emoji) { emoji in
                        Task {
                            do { try await model.setEmoji(emoji); showIcons = false }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(model.busy)
                }
                Text(page.title)
                    .font(.system(size: 32, weight: .bold))
                    .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.toggleFavorite(page.id)
                } label: {
                    Image(systemName: model.library.favoritePageIDs.contains(page.id) ? "star.fill" : "star")
                        .foregroundStyle(model.library.favoritePageIDs.contains(page.id) ? Color.yellow : Color.secondary)
                }.buttonStyle(.plain).padding(.top, 8).help("Favorite page")
                    .accessibilityLabel(model.library.favoritePageIDs.contains(page.id) ? "Remove from Favorites" : "Add to Favorites")
            }
            VStack(alignment: .leading, spacing: 5) {
                if let timestamp = page.timestamp {
                    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                    Text("Edited \(date.formatted(.relative(presentation: .named)))\(page.lastUserDisplayName.map { " by " + $0 } ?? "")")
                        .foregroundStyle(.secondary)
                }
                Label(status, systemImage: statusIcon)
                    .foregroundStyle(model.document?.draft == nil ? Color.secondary : Color.orange)
            }.font(.caption)
        }
        .padding(.bottom, 8)
        .alert("Could Not Change Icon", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
    private var status: String {
        if model.document?.conflict != nil { return "Conflicting edits need review" }
        return model.document?.draft == nil ? "Available offline" : "Draft saved on this device"
    }
    private var statusIcon: String {
        if model.document?.conflict != nil { return "exclamationmark.triangle" }
        return model.document?.draft == nil ? "checkmark.icloud" : "pencil.circle"
    }
}

private struct PageEmojiPicker: View {
    let current: String?
    let choose: (String?) -> Void
    @State private var custom = ""
    private let emojis = ["📝", "📚", "💡", "📌", "🏠", "🚀", "🧭", "🗓️", "✅", "🔧", "💬", "🎨", "🌱", "❤️", "⭐️", "📊", "🧪", "🎯", "📁", "🤝", "🎉", "🔗", "📖", "🛠️"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Page Icon").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: 6) {
                ForEach(emojis, id: \.self) { emoji in
                    Button { choose(emoji) } label: {
                        Text(emoji).font(.title2).frame(width: 34, height: 34)
                            .background(current == emoji ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Or enter an emoji", text: $custom).textFieldStyle(.roundedBorder)
                Button("Use") { choose(custom.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(!validEmoji)
            }
            if current?.isEmpty == false { Button("Remove Icon", role: .destructive) { choose(nil) } }
        }.padding(18).frame(width: 292)
    }
    private var validEmoji: Bool {
        let value = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count == 1 && value.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 127 }
    }
}

struct LibraryHomeView: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.account == nil {
            ContentUnavailableView {
                Label("Welcome to Collectives", systemImage: "books.vertical")
            } description: {
                Text("Connect your Nextcloud account to read and write together.")
            } actions: { Button("Add Account…") { model.beginLogin() } }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Home").font(.largeTitle.weight(.bold))
                        Text("Pick up where you left off, \(model.account?.userID ?? "").")
                            .foregroundStyle(.secondary)
                    }
                    if model.pendingCount > 0 {
                        Label("\(model.pendingCount) drafts saved on this device", systemImage: "pencil.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    pageSection("Favorites", ids: model.library.favoritePageIDs, symbol: "star", empty: "Favorite a page using its star or context menu.")
                    pageSection("Recently Opened", ids: model.library.recentPageIDs, symbol: "clock", empty: "Open a page from a collective to start your reading history.")
                }.frame(maxWidth: 820, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }
        }
    }
    private func pageSection(_ title: String, ids: [Int], symbol: String, empty: String) -> some View {
        let pages = ids.compactMap { id in model.allPages.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            if pages.isEmpty { Text(empty).font(.callout).foregroundStyle(.secondary) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(pages) { page in
                        Button { Task { await model.openLibraryPage(page) } } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    if let emoji = page.emoji, !emoji.isEmpty { Text(emoji) }
                                    else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                                    Text(page.title).font(.headline).lineLimit(1)
                                }
                                Text(collectiveName(page)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(excerpt(page)).font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.12), lineWidth: 1) }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.busy)
                            .contextMenu {
                                Button(model.library.favoritePageIDs.contains(page.id) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") { model.toggleFavorite(page.id) }
                            }
                    }
                }
            }
        }
    }
    private func collectiveName(_ page: Page) -> String {
        model.snapshot.collectives.first { $0.id == model.collectiveID(for: page.id) }?.name ?? "Downloaded page"
    }
    private func excerpt(_ page: Page) -> String {
        guard let doc = model.snapshot.documents[String(page.id)] else { return "Open to download this page." }
        let text = doc.draft ?? doc.markdown
        return String((text.components(separatedBy: .newlines).first { !$0.isEmpty && !$0.hasPrefix("#") } ?? "").prefix(140))
    }
}

struct RememberedPageOutline<Row: View>: View {
    let nodes: [PageNode]
    let accountID: UUID
    let collectiveID: Int
    let selectedPageID: Int?
    let row: (PageNode) -> Row
    @AppStorage private var expandedIDs: String
    init(nodes: [PageNode], accountID: UUID, collectiveID: Int, selectedPageID: Int?, @ViewBuilder row: @escaping (PageNode) -> Row) {
        self.nodes = nodes; self.accountID = accountID; self.collectiveID = collectiveID
        self.selectedPageID = selectedPageID; self.row = row
        _expandedIDs = AppStorage(wrappedValue: "", "outline.\(accountID.uuidString).\(collectiveID)")
    }
    private var expansion: Binding<Set<Int>> {
        Binding(get: { Set(expandedIDs.split(separator: ",").compactMap { Int($0) }) },
            set: { expandedIDs = $0.sorted().map(String.init).joined(separator: ",") })
    }
    var body: some View {
        ForEach(nodes) { node in OutlineBranch(node: node, expanded: expansion, row: row) }
            .onChange(of: selectedPageID, initial: true) { _, selected in
                guard let selected else { return }
                let ancestors = PageTree.path(to: selected, pages: flattened(nodes)).dropLast().map(\.id)
                expansion.wrappedValue.formUnion(ancestors)
            }
    }
    private func flattened(_ nodes: [PageNode]) -> [Page] {
        nodes.flatMap { [$0.page] + flattened($0.children ?? []) }
    }
}

private struct OutlineBranch<Row: View>: View {
    let node: PageNode
    @Binding var expanded: Set<Int>
    let row: (PageNode) -> Row
    @ViewBuilder var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(node.id) }, set: { value in
                if value { expanded.insert(node.id) } else { expanded.remove(node.id) }
            })) {
                ForEach(children) { child in OutlineBranch(node: child, expanded: $expanded, row: row) }
            } label: {
                NavigationLink(value: node.id) { row(node) }
            }
        } else {
            NavigationLink(value: node.id) { row(node) }
        }
    }
}

struct NewPageRequest: Identifiable {
    let id = UUID()
    let accountID: UUID
    let collectiveID: Int
    let collectiveName: String
    let parentID: Int
}

struct NewPageSheet: View {
    @Bindable var model: AppModel
    let request: NewPageRequest
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var parentID: Int
    @State private var submitting = false
    @State private var error: String?
    @State private var unconfirmed = false
    @FocusState private var titleFocused: Bool

    init(model: AppModel, request: NewPageRequest, onCreated: @escaping () -> Void) {
        self.model = model; self.request = request; self.onCreated = onCreated
        _parentID = State(initialValue: request.parentID)
    }
    private var pages: [Page] { model.snapshot.pages[String(request.collectiveID)] ?? [] }
    private var validTitle: Bool { (try? PageCreator.title(title)) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Page").font(.title2.bold())
            Text(request.collectiveName).foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $title).focused($titleFocused)
                    .onSubmit { if validTitle && !submitting && !unconfirmed { create() } }
                Picker("Parent page", selection: $parentID) {
                    ForEach(pages.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { page in
                        Text(parentName(page)).tag(page.id)
                    }
                }
            }.disabled(submitting || unconfirmed)
            Text("Creating a page requires a connection. It will be downloaded for offline editing when possible.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                if submitting { ProgressView().controlSize(.small); Text("Creating page…").foregroundStyle(.secondary) }
                Spacer()
                Button(unconfirmed ? "Close" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(submitting)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validTitle || submitting || unconfirmed || model.busy)
            }
        }
        .padding(24).frame(idealWidth: 440)
        #if os(macOS)
        .frame(width: 440)
        #endif
        .interactiveDismissDisabled(submitting)
        .onAppear { titleFocused = true }
    }
    private func parentName(_ page: Page) -> String {
        if page.parentId == 0 { return request.collectiveName + " (top level)" }
        return PageTree.path(to: page.id, pages: pages).dropFirst().map(\.title).joined(separator: " › ")
    }
    private func create() {
        guard !submitting, !unconfirmed, validTitle else { return }
        submitting = true; error = nil
        Task {
            do {
                try await model.createPage(title: title, parentID: parentID,
                    collectiveID: request.collectiveID, accountID: request.accountID)
                onCreated(); dismiss()
            } catch {
                self.error = error.localizedDescription
                if case PageCreationError.unconfirmed = error { unconfirmed = true }
            }
            submitting = false
        }
    }
}

struct RenamePageRequest: Identifiable {
    let id = UUID()
    let accountID: UUID
    let collectiveID: Int
    let page: Page
}

struct RenamePageSheet: View {
    @Bindable var model: AppModel
    let request: RenamePageRequest
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var submitting = false
    @State private var error: String?
    @State private var unconfirmed = false
    @FocusState private var titleFocused: Bool
    init(model: AppModel, request: RenamePageRequest) {
        self.model = model; self.request = request
        _title = State(initialValue: request.page.title)
    }
    private var canRename: Bool {
        guard let normalized = try? PageCreator.title(title) else { return false }
        return normalized != request.page.title && !submitting && !unconfirmed && !model.busy
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename Page").font(.title2.bold())
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).focused($titleFocused)
                .onSubmit { if canRename { rename() } }
                .disabled(submitting || unconfirmed)
            Text("Renaming requires a connection and updates the page name and subpage paths. Markdown content and local drafts stay unchanged.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                if submitting { ProgressView().controlSize(.small); Text("Renaming…").foregroundStyle(.secondary) }
                Spacer()
                Button(unconfirmed ? "Close" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(submitting)
                Button("Rename") { rename() }.keyboardShortcut(.defaultAction).disabled(!canRename)
            }
        }
        .padding(24).frame(idealWidth: 440)
        #if os(macOS)
        .frame(width: 440)
        #endif
        .interactiveDismissDisabled(submitting)
        .onAppear { titleFocused = true }
    }
    private func rename() {
        guard canRename else { return }
        submitting = true; error = nil
        Task {
            do {
                try await model.renamePage(title: title, pageID: request.page.id,
                    collectiveID: request.collectiveID, accountID: request.accountID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                if case PageRenamingError.unconfirmed = error { unconfirmed = true }
            }
            submitting = false
        }
    }
}
