import SwiftUI
import CollectivesCore
#if os(macOS)
import AppKit
#endif

enum AppSurface {
    static var chrome: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
    static var document: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

@main
struct CollectivesApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("automaticSync") private var automaticSync = true
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        if automaticSync { await model.syncPending(automatic: true) }
                        do { try await Task.sleep(for: .seconds(30)) }
                        catch { return }
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 750)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Current Page") { Task { await model.sync() } }
                    .keyboardShortcut("s").disabled(model.busy || model.selectedPage == nil)
                Button("Sync All Drafts") { Task { await model.syncPending() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.busy)
                Toggle("Automatically Sync Active Account", isOn: $automaticSync)
            }
        }
        #endif
        #if os(macOS)
        Settings { AppSettingsView(model: model) }
        #endif
    }
}

@MainActor @Observable
final class AppModel {
    var accounts: [Account] = []
    var activeID: UUID?
    var snapshot = AccountSnapshot()
    var selectedCollective: Int?
    var selectedPage: Page?
    var text = ""
    var message = "Add an account to get started."
    var busy = false
    var showLogin = false
    var settingsLogin = false
    var loginServer = "https://"
    var started = false
    var library = PageLibraryState()
    private let preferences = LibraryPreferences()
    private let store: LocalStore
    private let credentials = KeychainCredentialStore()
    private var pendingPersistence: Task<Void, Never>?
    private var persistenceFailed = false
    private var lastEdit = Date.distantPast

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = LocalStore(root: base.appendingPathComponent("Collectives", isDirectory: true))
    }
    var account: Account? { accounts.first { $0.id == activeID } }
    var pages: [Page] { snapshot.pages[String(selectedCollective ?? -1)] ?? [] }
    var document: CachedDocument? { selectedPage.flatMap { snapshot.documents[String($0.id)] } }
    var pendingCount: Int { snapshot.documents.values.filter { $0.draft != nil }.count }
    var conflictCount: Int { snapshot.documents.values.filter { $0.conflict != nil }.count }
    var downloadedCount: Int { pages.filter { snapshot.documents[String($0.id)] != nil }.count }
    var canEdit: Bool { snapshot.collectives.first { $0.id == selectedCollective }?.canEdit == true }

    func start() async {
        guard !started else { return }; started = true
        do {
            accounts = try await store.accounts()
            if let target = accounts.first(where: { $0.id == preferences.lastAccountID }) ?? accounts.first {
                await selectAccount(target.id)
                await restoreSelection()
            }
        } catch { message = error.localizedDescription }
    }
    func client() throws -> CollectivesClient {
        guard let account, let credential = try credentials.credential(accountID: account.id) else {
            throw CollectivesError.invalidResponse
        }
        return CollectivesClient(account: account, credential: credential)
    }
    func selectAccount(_ id: UUID) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft successfully before switching accounts."; return }
        let loaded: AccountSnapshot
        do { loaded = try await store.snapshot(accountID: id) }
        catch { message = error.localizedDescription; return }
        activeID = id; selectedCollective = nil; selectedPage = nil; text = ""
        snapshot = loaded
        library = preferences.load(accountID: id)
        preferences.lastAccountID = id
        do {
            snapshot.collectives = try await client().collectives()
            try await persist(); message = "Collectives refreshed."
        } catch { message = "Using cached content. \(error.localizedDescription)" }
    }
    func persist() async throws {
        guard let id = activeID else { return }
        try await store.saveSnapshot(snapshot, accountID: id)
    }
    func refresh() async {
        guard !busy, account != nil else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        do {
            snapshot.collectives = try await client().collectives()
            try await persist(); message = "Collectives refreshed. Download pages to edit offline."
        } catch { message = "Using cached content. \(error.localizedDescription)" }
    }
    @discardableResult
    func openCollective(_ id: Int) async -> Bool {
        guard !busy, snapshot.collectives.contains(where: { $0.id == id }) else { return false }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft before switching collectives."; return false }
        selectedCollective = id; selectedPage = nil; text = ""
        library.collectiveID = id; library.pageID = nil; saveLibrary()
        do {
            let pages = try await client().pages(collectiveID: id)
            snapshot.pages[String(id)] = pages
            for page in pages {
                if var cached = snapshot.documents[String(page.id)] {
                    cached.page = page
                    snapshot.documents[String(page.id)] = cached
                }
            }
            try await persist(); message = "Select a page."
        } catch { message = "Using cached pages. \(error.localizedDescription)" }
        return true
    }
    func openPage(_ page: Page) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        selectedPage = page
        if let collectiveID = selectedCollective {
            library.visit(pageID: page.id, collectiveID: collectiveID); saveLibrary()
        }
        let key = String(page.id)
        if let cached = snapshot.documents[key] {
            text = cached.draft ?? cached.markdown
            message = cached.conflict != nil ? "Conflict: local draft preserved. Review the server copy below." :
                (cached.draft != nil ? "Local draft waiting to sync." : "Downloaded page. Refresh from server to check for updates.")
            return
        }
        text = ""
        do {
            let body = try await client().download(page: page)
            snapshot.documents[key] = CachedDocument(page: page, collectiveID: selectedCollective!, markdown: body.markdown, etag: body.etag)
            try await persist(); text = body.markdown; message = "Downloaded for offline editing."
        } catch { message = error.localizedDescription }
    }
    func openDraft(_ pageID: Int) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard let doc = snapshot.documents[String(pageID)] else { return }
        selectedCollective = doc.collectiveID
        selectedPage = doc.page
        library.visit(pageID: doc.page.id, collectiveID: doc.collectiveID); saveLibrary()
        text = doc.draft ?? doc.markdown
        message = doc.conflict == nil ? "Local draft waiting to sync." : "Conflict: compare your draft with the server version."
    }
    func edited(_ value: String) {
        guard let page = selectedPage, var doc = snapshot.documents[String(page.id)], canEdit, !busy else { return }
        text = value
        lastEdit = Date()
        doc.draft = value == doc.markdown ? nil : value
        snapshot.documents[String(page.id)] = doc
        guard let id = activeID else { return }
        let saved = snapshot
        let previous = pendingPersistence
        message = "Saving draft locally…"
        pendingPersistence = Task {
            await previous?.value
            do {
                try await store.saveSnapshot(saved, accountID: id)
                persistenceFailed = false
                if activeID == id { message = "Draft saved locally; waiting to sync." }
            } catch { persistenceFailed = true; message = "Draft not saved: \(error.localizedDescription)" }
        }
    }
    func sync() async {
        guard !busy, let page = selectedPage else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed, let doc = snapshot.documents[String(page.id)] else { return }
        guard doc.conflict == nil else { message = "Resolve the conflict before syncing."; return }
        do {
            let updated = try await DocumentSynchronizer.synchronize(document: doc, api: client())
            var next = snapshot
            next.documents[String(page.id)] = updated
            guard let id = activeID else { return }
            try await store.saveSnapshot(next, accountID: id)
            snapshot = next; text = updated.draft ?? updated.markdown
            message = updated.conflict == nil ? "Synced with server." : "Server changed. Local draft preserved for review."
        } catch { message = "Draft retained. \(error.localizedDescription)" }
    }
    func downloadCollective() async {
        guard !busy, let collectiveID = selectedCollective, let id = activeID else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { return }
        message = "Downloading page text for offline use…"
        let previous = snapshot
        do {
            let localStore = store
            snapshot = try await OfflineDownloader.download(collectiveID: collectiveID, snapshot: snapshot, api: client()) { value in
                try await localStore.saveSnapshot(value, accountID: id)
            }
            updateEditor()
            message = "Downloaded \(downloadedCount) page bodies. Existing drafts preserved. Images and attachments are not downloaded yet."
        } catch {
            // Keep successful checkpoints if a later page fails.
            snapshot = (try? await store.snapshot(accountID: id)) ?? previous
            updateEditor()
            message = "Download incomplete; saved pages remain offline. \(error.localizedDescription)"
        }
    }
    func syncPending(automatic: Bool = false) async {
        guard !busy, !showLogin, !settingsLogin else { return }
        if automatic {
            guard Date().timeIntervalSince(lastEdit) >= 5,
                  snapshot.documents.values.contains(where: { $0.draft != nil && $0.conflict == nil }) else { return }
        }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { return }
        let targets = automatic ? accounts.filter { $0.id == activeID } : accounts
        var synced = 0; var conflicts = 0; var failures = 0
        for target in targets {
            if Task.isCancelled { break }
            do {
                var local = target.id == activeID ? snapshot : try await store.snapshot(accountID: target.id)
                let pending = local.documents.keys.sorted().filter { local.documents[$0]?.draft != nil }
                guard !pending.isEmpty else { continue }
                guard let credential = try credentials.credential(accountID: target.id) else { failures += 1; continue }
                let api = CollectivesClient(account: target, credential: credential)
                for key in pending {
                    try Task.checkCancellation()
                    guard let doc = local.documents[key] else { continue }
                    if doc.conflict != nil { conflicts += 1; continue }
                    let updated = try await DocumentSynchronizer.synchronize(document: doc, api: api)
                    var next = local
                    next.documents[key] = updated
                    try await store.saveSnapshot(next, accountID: target.id)
                    local = next
                    if target.id == activeID { snapshot = next; updateEditor() }
                    if updated.conflict != nil { conflicts += 1 } else { synced += 1 }
                }
            } catch is CancellationError { break }
            catch { failures += 1 }
        }
        message = "Synced \(synced) drafts; \(conflicts) conflicts; \(failures) accounts need retry. Unsynced work is retained."
    }
    private func updateEditor() {
        if let doc = document { text = doc.draft ?? doc.markdown }
    }
    func resolveConflict(useServer: Bool) async {
        guard !busy, let page = selectedPage, var doc = document, let remote = doc.conflict else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        let local = doc.draft ?? text
        doc.markdown = remote.markdown; doc.etag = remote.etag
        doc.draft = useServer ? nil : local; doc.conflict = nil
        snapshot.documents[String(page.id)] = doc
        do {
            try await persist(); text = doc.draft ?? doc.markdown
            message = useServer ? "Server version selected." : "Local version queued against reviewed server revision."
        } catch { message = error.localizedDescription }
    }
    func beginLogin(server: URL? = nil) {
        loginServer = server?.absoluteString ?? "https://"
        showLogin = true
    }
    func accountBackup(_ id: UUID) async throws -> String {
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.invalidResponse }
        let saved = try await store.snapshot(accountID: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(saved), as: UTF8.self)
    }
    func removeAccount(_ id: UUID) async throws {
        guard !busy else { throw CollectivesError.invalidResponse }
        busy = true
        defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.invalidResponse }
        let credentialStore = credentials
        try await store.removeAccount(accountID: id) { try credentialStore.remove(accountID: $0) }
        accounts.removeAll { $0.id == id }
        preferences.remove(accountID: id)
        if activeID == id {
            activeID = nil; snapshot = AccountSnapshot()
            selectedCollective = nil; selectedPage = nil; text = ""
            busy = false
            if let first = accounts.first { await selectAccount(first.id) }
        }
        message = "Account removed from this device."
    }
    private func saveLibrary() {
        if let id = activeID { preferences.save(library, accountID: id) }
    }
    private func restoreSelection() async {
        let saved = library
        guard let collectiveID = saved.collectiveID,
              snapshot.collectives.contains(where: { $0.id == collectiveID }) else { return }
        if await openCollective(collectiveID), let pageID = saved.pageID {
            if let page = pages.first(where: { $0.id == pageID }) { await openPage(page) }
            else if snapshot.documents[String(pageID)]?.draft != nil { await openDraft(pageID) }
        }
    }
    func openHome() async {
        guard !busy else { return }
        await pendingPersistence?.value
        guard !persistenceFailed else { return }
        selectedCollective = nil; selectedPage = nil; text = ""
        library.collectiveID = nil; library.pageID = nil; saveLibrary()
    }
    func toggleFavorite(_ pageID: Int) {
        library.toggleFavorite(pageID); saveLibrary()
    }
    var allPages: [Page] {
        var unique: [Int: Page] = [:]
        for page in snapshot.pages.values.flatMap({ $0 }) { unique[page.id] = page }
        for doc in snapshot.documents.values where unique[doc.page.id] == nil { unique[doc.page.id] = doc.page }
        return Array(unique.values)
    }
    func collectiveID(for pageID: Int) -> Int? {
        snapshot.documents[String(pageID)]?.collectiveID ?? snapshot.pages.first(where: { $0.value.contains(where: { $0.id == pageID }) }).flatMap { Int($0.key) }
    }
    func openLibraryPage(_ page: Page) async {
        guard let collectiveID = collectiveID(for: page.id), !busy else { return }
        if selectedCollective != collectiveID { guard await openCollective(collectiveID) else { return } }
        await openPage(page)
    }
    func setEmoji(_ emoji: String?) async throws {
        guard !busy, canEdit, let page = selectedPage, let collectiveID = selectedCollective,
              let accountID = activeID else { throw CollectivesError.invalidResponse }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.invalidResponse }
        let updated = try await client().setPageEmoji(pageID: page.id, collectiveID: collectiveID, emoji: emoji)
        var next = snapshot
        next.pages[String(collectiveID)] = (next.pages[String(collectiveID)] ?? []).map { $0.id == page.id ? updated : $0 }
        if var cached = next.documents[String(page.id)] { cached.page = updated; next.documents[String(page.id)] = cached }
        try await store.saveSnapshot(next, accountID: accountID)
        snapshot = next; selectedPage = updated
    }
    func createPage(title: String, parentID: Int, collectiveID: Int, accountID: UUID) async throws {
        guard !busy, activeID == accountID, selectedCollective == collectiveID, canEdit else {
            throw CollectivesError.invalidResponse
        }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { throw PageCreationError.unsavedDraft }
        let result = try await PageCreator.create(title: title, parentID: parentID, collectiveID: collectiveID,
            snapshot: snapshot, api: client())
        let previous = snapshot
        snapshot = result.snapshot
        selectedPage = result.page
        text = document?.draft ?? document?.markdown ?? ""
        library.visit(pageID: result.page.id, collectiveID: collectiveID); saveLibrary()
        do {
            try await persist()
            message = (["Page created on the server."] + result.warnings).joined(separator: " ")
        } catch {
            if previous.documents[String(result.page.id)] == nil { snapshot.documents[String(result.page.id)] = nil }
            text = document?.draft ?? document?.markdown ?? ""
            message = "Page created on the server, but its local copy could not be saved. Refresh or reopen it when storage is available. \(error.localizedDescription)"
        }
    }
    func addAccount(_ login: LoginCredentials) async throws {
        guard !busy else { throw CollectivesError.invalidResponse }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.invalidResponse }
        let credential = Credential(loginName: login.loginName, appPassword: login.appPassword)
        let server = try ServerAddress.normalize(login.server)
        let provisional = Account(serverURL: server, userID: login.loginName)
        let userID = try await CollectivesClient(account: provisional, credential: credential).currentUserID()
        let existing = accounts.first { $0.serverURL == server && $0.userID == userID }
        let new = Account(id: existing?.id ?? UUID(), serverURL: server, userID: userID)
        try credentials.save(credential, accountID: new.id)
        if existing == nil { accounts.append(new) }
        try await store.saveAccounts(accounts)
        busy = false
        await selectAccount(new.id)
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("automaticSync") private var automaticSync = true
    @State private var search = ""
    @AppStorage("defaultPageMode") private var defaultPageMode = "preview"
    @AppStorage("closeSidebarAfterCollectiveSwitch") private var closeSidebarAfterCollectiveSwitch = false
    @State private var showSettings = false
    @State private var newPageRequest: NewPageRequest?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var editing = false
    @State private var showingOutline = false
    @State private var showingFind = false
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            VStack(spacing: 0) {
                accountSwitcher
                    .padding(.horizontal, 16).padding(.vertical, 14)
                List(selection: collectiveSelection) {
                    NavigationLink(value: 0) { Label("Home", systemImage: "house") }
                        .disabled(model.busy)
                    Section("Collectives") {
                        ForEach(model.snapshot.collectives) { collective in
                            NavigationLink(value: collective.id) {
                                HStack(spacing: 9) {
                                    if let emoji = collective.emoji, !emoji.isEmpty {
                                        Text(emoji).frame(width: 20)
                                    } else {
                                        Image(systemName: "books.vertical").foregroundStyle(.secondary).frame(width: 20)
                                    }
                                    Text(collective.name).lineLimit(1)
                                }
                            }.disabled(model.busy)
                        }
                    }
                    if !drafts.isEmpty {
                        Section("Drafts") {
                            ForEach(drafts, id: \.page.id) { doc in
                                Button {
                                    Task { await model.openDraft(doc.page.id); compactColumn = .detail }
                                } label: {
                                    HStack(spacing: 9) {
                                        pageIcon(doc.page, hasChildren: false)
                                        Text(doc.page.title).lineLimit(1)
                                        Spacer(minLength: 0)
                                        draftIndicator(doc)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(model.busy)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                sidebarFooter
            }
            .background(AppSurface.chrome)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
            .navigationTitle("Collectives")
        } content: {
            VStack(spacing: 0) {
                PageSearchField(text: $search)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                if model.selectedCollective == nil {
                    ContentUnavailableView("Choose a Collective", systemImage: "books.vertical")
                } else if !search.isEmpty && searchResults.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List(selection: pageSelection) {
                        if search.isEmpty {
                            if let accountID = model.activeID, let collectiveID = model.selectedCollective {
                                RememberedPageOutline(nodes: visibleTree, accountID: accountID,
                                    collectiveID: collectiveID, selectedPageID: model.selectedPage?.id) { node in
                                    pageRow(node.page, hasChildren: node.children != nil)
                                }.disabled(model.busy)
                            }
                        } else {
                            ForEach(searchResults) { page in
                                NavigationLink(value: page.id) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        pageRow(page, hasChildren: false)
                                        Text(pagePath(page).map { $0.title }.joined(separator: " › "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.disabled(model.busy)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                }
                if model.selectedCollective != nil {
                    HStack {
                        Label("\(model.pages.count) pages", systemImage: "doc.text")
                        Spacer()
                        Text("\(model.downloadedCount) offline")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .background(AppSurface.chrome)
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 440)
            .navigationTitle(collectiveTitle)
            .toolbar {
                Button("New Page", systemImage: "square.and.pencil") { beginNewPage() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.busy || !model.canEdit || model.pages.isEmpty)
                Menu {
                    Button("New Page…", systemImage: "doc.badge.plus") { beginNewPage() }
                        .disabled(!model.canEdit || model.pages.isEmpty)
                    Button("Download for Offline Editing", systemImage: "arrow.down.circle") { Task { await model.downloadCollective() } }
                    Button("Refresh Pages", systemImage: "arrow.clockwise") {
                        if let id = model.selectedCollective { Task { await model.openCollective(id) } }
                    }
                } label: { Label("Collective Actions", systemImage: "ellipsis.circle") }
                    .disabled(model.busy || model.selectedCollective == nil)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                if let page = model.selectedPage, model.document != nil {
                    HStack(spacing: 5) {
                        Text(collectiveTitle)
                        ForEach(pagePath(page)) { ancestor in
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            Button(ancestor.title) { Task { await model.openPage(ancestor) } }
                                .buttonStyle(.plain)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        Text(page.title).fontWeight(.medium).foregroundStyle(.primary)
                            .layoutPriority(1)
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if editing && model.canEdit {
                        DocumentHeader(model: model, page: page)
                            .frame(maxWidth: 740).frame(maxWidth: .infinity)
                            .padding(.horizontal, 28)
                        MarkdownSourceEditor(text: Binding(get: { model.text }, set: { model.edited($0) }), disabled: model.busy)
                            .id(pageIdentity)
                    } else {
                        MarkdownReader(showingOutline: $showingOutline, showingFind: $showingFind, model: model, source: model.text, page: page, account: model.account,
                            pages: model.pages, client: try? model.client()) { destination in
                                Task { await model.openPage(destination) }
                            }
                            .id("\(model.activeID?.uuidString ?? "")/\(page.id)")
                    }
                    if let remote = model.document?.conflict {
                        DisclosureGroup("Compare server version") {
                            ScrollView { Text(remote.markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                        }
                        HStack {
                            Button("Queue Local Version") { Task { await model.resolveConflict(useServer: false) } }
                            Button("Use Server Version", role: .destructive) { Task { await model.resolveConflict(useServer: true) } }
                        }.disabled(model.busy)
                    }
                } else if let page = model.selectedPage, !model.busy {
                    ContentUnavailableView {
                        Label("Page Not Downloaded", systemImage: "arrow.down.doc")
                    } description: {
                        Text("Connect to download this page before reading or editing it.")
                    } actions: {
                        Button("Download Page") { Task { await model.openPage(page) } }
                    }
                } else if model.busy && model.selectedPage != nil {
                    ProgressView("Loading page…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.selectedCollective == nil {
                    LibraryHomeView(model: model)
                } else {
                    ContentUnavailableView("Select a Page", systemImage: "doc.text", description: Text("Choose a page to read, or download this collective for offline editing."))
                }
                if model.busy { ProgressView() }
                Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppSurface.document)
            .toolbar {
                if model.selectedPage != nil, model.document != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Picker("Page Mode", selection: $editing) {
                            Text("Preview").tag(false)
                            Text("Edit").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                        .disabled(model.busy || !model.canEdit)
                        ShareLink("Share Markdown", item: model.text)
                            .labelStyle(.iconOnly).help("Share Markdown source")
                        Button(model.document?.draft == nil ? "Reload Page" : "Sync Page",
                               systemImage: model.document?.draft == nil ? "arrow.clockwise" : "arrow.triangle.2.circlepath") {
                            Task { await model.sync() }
                        }
                        .labelStyle(.iconOnly)
                        .help(model.document?.draft == nil ? "Reload page from server" : "Sync page, preserving conflicting edits")
                        .disabled(model.busy)
                    }
                    #if os(macOS)
                    ToolbarItem(placement: .primaryAction) { Spacer() }
                    #endif
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            if showingOutline && !editing { showingOutline = false }
                            else { editing = false; showingOutline = true }
                        } label: {
                            Label("Table of Contents", systemImage: "sidebar.right")
                        }
                        .labelStyle(.iconOnly)
                        .help(showingOutline && !editing ? "Hide table of contents" : "Show table of contents")
                        .accessibilityValue(showingOutline && !editing ? "Shown" : "Hidden")
                        Button {
                            editing = false; showingFind = true
                        } label: { Label("Find in Page", systemImage: "magnifyingglass") }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut("f", modifiers: .command)
                        .help("Find in page (⌘F)")
                    }
                }
            }
        }
        #if os(macOS)
        .toolbarBackground(AppSurface.chrome, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        #endif
        .sheet(item: $newPageRequest) { request in
            NewPageSheet(model: model, request: request) {
                search = ""; compactColumn = .detail
            }
        }
        .sheet(isPresented: $model.showLogin) { LoginView(model: model) }
        #if !os(macOS)
        .sheet(isPresented: $showSettings) { AppSettingsView(model: model) }
        #endif
        .onChange(of: pageIdentity, initial: true) { _, _ in editing = defaultPageMode == "edit" }

    }
    private func beginNewPage(parent: Page? = nil) {
        guard !model.busy, model.canEdit, let accountID = model.activeID,
              let collectiveID = model.selectedCollective,
              let parent = parent ?? model.pages.first(where: { $0.parentId == 0 }) else { return }
        newPageRequest = NewPageRequest(accountID: accountID, collectiveID: collectiveID,
            collectiveName: collectiveTitle, parentID: parent.id)
    }
    private var pageIdentity: String { "\(model.activeID?.uuidString ?? "")/\(model.selectedPage?.id.description ?? "")" }
    private func append(_ snippet: String) { model.edited(model.text + snippet) }
    private var collectiveTitle: String {
        model.snapshot.collectives.first { $0.id == model.selectedCollective }?.name ?? "Pages"
    }
    private var drafts: [CachedDocument] {
        model.snapshot.documents.values.filter { $0.draft != nil }.sorted { $0.page.title.localizedStandardCompare($1.page.title) == .orderedAscending }
    }
    private var collectiveSelection: Binding<Int?> {
        Binding(get: { model.selectedCollective ?? 0 }, set: { id in
            if id == 0 {
                Task { await model.openHome(); compactColumn = .detail }
            } else if let id {
                Task {
                    let previous = model.selectedCollective
                    if await model.openCollective(id) {
                        search = ""
                        if previous != id && closeSidebarAfterCollectiveSwitch {
                            columnVisibility = .doubleColumn
                            compactColumn = .content
                        }
                    }
                }
            }
        })
    }
    private var pageSelection: Binding<Int?> {
        Binding(get: { model.selectedPage?.id }, set: { id in
            if let page = model.pages.first(where: { $0.id == id }) { Task { await model.openPage(page) } }
        })
    }
    private var visibleTree: [PageNode] {
        PageTree.build(pages: model.pages).flatMap { node -> [PageNode] in
            if node.page.parentId == 0 {
                return [PageNode(page: node.page, children: nil)] + (node.children ?? [])
            }
            return [node]
        }
    }
    private func pagePath(_ page: Page) -> [Page] {
        Array(PageTree.path(to: page.id, pages: model.pages).dropLast())
    }
    private var searchResults: [Page] {
        model.pages.filter { page in
            let doc = model.snapshot.documents[String(page.id)]
            return page.title.localizedCaseInsensitiveContains(search) ||
                (doc.map { ($0.draft ?? $0.markdown).localizedCaseInsensitiveContains(search) } ?? false)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    @ViewBuilder private func pageIcon(_ page: Page, hasChildren: Bool) -> some View {
        if let emoji = page.emoji, !emoji.isEmpty {
            Text(emoji).frame(width: 20)
        } else {
            Image(systemName: page.parentId == 0 ? "house" : (hasChildren ? "folder" : "doc.text"))
                .foregroundStyle(.secondary).frame(width: 20)
        }
    }
    @ViewBuilder private func draftIndicator(_ doc: CachedDocument) -> some View {
        if doc.conflict != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help("Conflicting edits need review").accessibilityLabel("Conflict")
        } else if doc.draft != nil {
            Circle().fill(.orange).frame(width: 6, height: 6)
                .help("Draft waiting to sync").accessibilityLabel("Unsynced draft")
        }
    }
    private func pageRow(_ page: Page, hasChildren: Bool) -> some View {
        HStack(spacing: 7) {
            pageIcon(page, hasChildren: hasChildren)
            Text(page.title).lineLimit(1)
            Spacer(minLength: 0)
            if let doc = model.snapshot.documents[String(page.id)] { draftIndicator(doc) }
        }
        .contextMenu {
            Button(model.library.favoritePageIDs.contains(page.id) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") { model.toggleFavorite(page.id) }
            Button("Open Page", systemImage: "doc.text") { Task { await model.openPage(page) } }
            Button("New Subpage…", systemImage: "doc.badge.plus") { beginNewPage(parent: page) }
                .disabled(model.busy || !model.canEdit)
        }
        .help(([collectiveTitle] + pagePath(page).map { $0.title } + [page.title]).joined(separator: " › "))
    }
    private var accountSwitcher: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    search = ""; Task { await model.selectAccount(account.id) }
                } label: {
                    Label("\(account.userID) · \(account.serverURL.host ?? "")", systemImage: account.id == model.activeID ? "checkmark" : "person")
                }
            }
            if !model.accounts.isEmpty { Divider() }
            Button("Add Account…", systemImage: "person.badge.plus") { model.beginLogin() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.account?.userID ?? "Add Account").font(.headline).foregroundStyle(.primary)
                    Text(model.account?.serverURL.host ?? "Connect to Nextcloud")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(model.busy)
        .accessibilityLabel("Switch Account")
    }
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: model.conflictCount > 0 ? "exclamationmark.triangle" : "checkmark.icloud").foregroundStyle(.secondary) }
            Text(model.pendingCount == 0 ? "No pending drafts" : "\(model.pendingCount) pending drafts")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Menu {
                Button("Sync All Accounts", systemImage: "arrow.triangle.2.circlepath") { Task { await model.syncPending() } }
                Button("Refresh Collectives", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                Divider()
                Toggle("Auto-sync Active Account", isOn: $automaticSync)
            } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize().disabled(model.busy)
                .accessibilityLabel("Sync Actions")
            #if os(macOS)
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("Settings")
                .accessibilityLabel("Settings")
            #else
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).accessibilityLabel("Settings")
            #endif
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

}

struct LoginView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var server = "https://"
    @State private var status = "Approve access in your browser. Your account password stays there."
    @State private var loginTask: Task<Void, Never>?
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Nextcloud").font(.title2)
            TextField("Server URL", text: $server).textFieldStyle(.roundedBorder).disabled(working)
            Text(status).font(.callout).textSelection(.enabled)
            if working { ProgressView() }
            HStack {
                Button("Cancel") { loginTask?.cancel(); dismiss() }
                Spacer()
                Button("Sign In with Browser") { begin() }.disabled(working)
            }
        }.padding(24).frame(minWidth: 300, idealWidth: 440)
        .onAppear { server = model.loginServer }
        .onDisappear { loginTask?.cancel() }
    }
    private func begin() {
        working = true
        loginTask = Task { @MainActor in
            defer { working = false }
            do {
                guard let url = URL(string: server) else { throw CollectivesError.invalidServer }
                let api = LoginFlowClient()
                let flow = try await api.begin(serverURL: url)
                openURL(flow.login)
                status = "Waiting for browser approval…"
                let deadline = Date().addingTimeInterval(20 * 60)
                while Date() < deadline {
                    try Task.checkCancellation()
                    if let login = try await api.poll(flow, serverURL: url) {
                        try Task.checkCancellation()
                        try await model.addAccount(login)
                        dismiss(); return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                status = "Login expired. Try again."
            } catch is CancellationError {} catch { status = error.localizedDescription }
        }
    }
}

struct PageSearchField: View {
    @Binding var text: String
    var body: some View {
        #if os(macOS)
        NativePageSearchField(text: $text).frame(height: 24)
        #else
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search pages", text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
        }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        #endif
    }
}

#if os(macOS)
struct NativePageSearchField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search pages"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search page titles and downloaded text")
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}
#endif
