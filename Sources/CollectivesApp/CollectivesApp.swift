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
        Color(uiColor: .systemGroupedBackground)
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

private struct AutomaticSyncIdentity: Equatable {
    let active: Bool
    let accountID: UUID?
    let collectiveIDs: [Int]
}

@main
struct CollectivesApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            CollectivesWindow(sharedModel: model)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 750)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            PageNavigationCommands()
            PageCommands()
            WindowSyncCommands()
        }
        #endif
        #if os(macOS)
        Settings { AppSettingsView(model: model) }
        #endif
    }
}

private struct CollectivesWindow: View {
    let sharedModel: AppModel
    @State private var windowModel: AppModel?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("automaticSync") private var automaticSync = true
    var body: some View {
        Group {
            if let model = windowModel {
                ContentView(model: model)
                    #if os(macOS)
                    .focusedSceneValue(\.collectivesWindow, model)
                    #endif
                    .task { await model.start() }
                    .task(id: AutomaticSyncIdentity(
                        active: scenePhase == .active && automaticSync && model.startupComplete,
                        accountID: model.activeID,
                        collectiveIDs: model.snapshot.collectives.map(\.id)
                    )) {
                        guard scenePhase == .active, automaticSync, model.startupComplete else { return }
                        await model.runAutomaticSync()
                    }
                    .onDisappear { Task { await model.finishTextEditing() } }
            } else {
                ProgressView().task { windowModel = sharedModel.newWindow() }
            }
        }
    }
}

@MainActor @Observable
final class AppModel {
    var accounts: [Account] {
        get { session.accounts }
        set { session.accounts = newValue }
    }
    var accountCollectives: [UUID: [Collective]] {
        get { session.accountCollectives }
        set { session.accountCollectives = newValue }
    }
    var collectiveListingErrors: [UUID: String] {
        get { session.collectiveListingErrors }
        set { session.collectiveListingErrors = newValue }
    }
    private(set) var sourceEditorGeneration = UUID()
    var activeID: UUID? {
        didSet { if activeID != oldValue { sourceEditorGeneration = UUID() } }
    }
    let windowID = UUID()
    let session: AppSession
    private var emptySnapshot = AccountSnapshot()
    var snapshot: AccountSnapshot {
        get { activeID.flatMap { session.snapshots[$0] } ?? emptySnapshot }
        set {
            guard let id = activeID else { emptySnapshot = newValue; return }
            session.snapshots[id] = newValue
            session.refreshWindows(accountID: id, except: windowID)
        }
    }
    var selectedCollective: Int? {
        didSet { if selectedCollective != oldValue { message = "" } }
    }
    var selectedPage: Page? {
        didSet {
            guard selectedPage?.id != oldValue?.id else { return }
            sourceEditorGeneration = UUID(); message = ""
        }
    }
    var text = ""
    /// Transient feedback; persistent state lives in `syncSummary` and the page header.
    var message = "" {
        didSet {
            undoableTrash = nil
            messageClearTask?.cancel()
            guard !message.isEmpty else { messageClearTask = nil; return }
            messageGeneration += 1
            messageClearTask = Task { [weak self, lifetime = messageLifetime, generation = messageGeneration] in
                try? await Task.sleep(for: lifetime)
                guard !Task.isCancelled, let self, self.messageGeneration == generation else { return }
                self.message = ""
            }
        }
    }
    var messageLifetime: Duration = .seconds(6)
    private var messageGeneration = 0
    var undoableTrash: PageOrganizationRequest?
    private(set) var queuedPage: Page?
    private var openingPage = false
    private var navigationRequest = 0
    /// Waits for unrelated work to finish. Returns false when a later navigation tap replaced this one.
    func waitForNavigationTurn(openingPage pageTap: Bool = false) async -> Bool {
        navigationRequest &+= 1
        let request = navigationRequest
        while busy && !(pageTap && openingPage) { await session.waitUntilIdle() }
        return request == navigationRequest
    }
    private(set) var messageClearTask: Task<Void, Never>?
    var busy: Bool {
        get { session.busy }
        set { session.busy = newValue }
    }
    var syncing: Bool {
        get { session.syncing }
        set { session.syncing = newValue }
    }
    var isCancellingSync: Bool {
        get { session.isCancellingSync }
        set { session.isCancellingSync = newValue }
    }
    var automaticSyncPaused: Bool {
        get { session.automaticSyncPaused }
        set { session.automaticSyncPaused = newValue }
    }
    var canCancelSync: Bool { (syncing || syncActivity != nil) && !isCancellingSync }
    var syncActivity: SyncActivity? {
        get { session.syncActivity }
        set { session.syncActivity = newValue }
    }
    var syncIssues: [UUID: SyncIssue] {
        get { session.syncIssues }
        set { session.syncIssues = newValue }
    }
    var textSession: EmbeddedTextSession?
    var pageMode: PageViewMode = .view {
        didSet { if pageMode != oldValue { sourceEditorGeneration = UUID() } }
    }
    let textRuntime = OfflineTextRuntime()
    private let modePreferences: PageModePreferences
    var showLogin = false
    var settingsLogin = false
    var loginServer = "https://"
    var started = false
    var startupComplete = false
    private var emptyLibrary = PageLibraryState()
    var library: PageLibraryState {
        get { activeID.flatMap { session.libraries[$0] } ?? emptyLibrary }
        set {
            if let id = activeID { session.libraries[id] = newValue }
            else { emptyLibrary = newValue }
        }
    }
    private let preferences: LibraryPreferences
    let store: LocalStore
    private let credentials = KeychainCredentialStore()
    private let makeClient: @MainActor (Account) async throws -> CollectivesClient
    var cachedClients: [Account: CollectivesClient] {
        get { session.cachedClients }
        set { session.cachedClients = newValue }
    }
    var preparingClients: [Account: ClientPreparation] {
        get { session.preparingClients }
        set { session.preparingClients = newValue }
    }
    var clientGeneration: UUID {
        get { session.clientGeneration }
        set { session.clientGeneration = newValue }
    }
    var accountSyncTasks: [UUID: Task<Void, Error>] {
        get { session.accountSyncTasks }
        set { session.accountSyncTasks = newValue }
    }
    var removingAccountIDs: Set<UUID> {
        get { session.removingAccountIDs }
        set { session.removingAccountIDs = newValue }
    }
    private var pushConnected = false
    private var remoteSyncRequested = false
    private var automaticSyncGeneration: UUID?
    var pendingPersistence: Task<Void, Never>? {
        get { session.pendingPersistence }
        set { session.pendingPersistence = newValue }
    }
    var persistenceFailed: Bool {
        get { session.persistenceFailed }
        set { session.persistenceFailed = newValue }
    }
    var savingDraft: Bool {
        get { session.savingDraft }
        set { session.savingDraft = newValue }
    }
    var draftSaveFailed: Bool { persistenceFailed }
    var editGeneration: UUID {
        get { session.editGeneration }
        set { session.editGeneration = newValue }
    }
    var syncBaselines: [UUID: AccountSnapshot] {
        get { session.syncBaselines }
        set { session.syncBaselines = newValue }
    }
    var checkpointSnapshots: [UUID: AccountSnapshot] {
        get { session.checkpointSnapshots }
        set { session.checkpointSnapshots = newValue }
    }
    var checkpointVersions: [UUID: Int] {
        get { session.checkpointVersions }
        set { session.checkpointVersions = newValue }
    }
    var lastEdit: Date {
        get { session.lastEdit }
        set { session.lastEdit = newValue }
    }
    var lastSyncDates: [UUID: Date] {
        get { session.lastSyncDates }
        set { session.lastSyncDates = newValue }
    }

    init(store: LocalStore? = nil, session: AppSession = AppSession(), preferences: LibraryPreferences = LibraryPreferences(),
         modePreferences: PageModePreferences = PageModePreferences(),
         makeClient: (@MainActor (Account) async throws -> CollectivesClient)? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.session = session
        self.store = store ?? LocalStore(root: base.appendingPathComponent("Collectives", isDirectory: true))
        self.preferences = preferences
        self.modePreferences = modePreferences
        self.makeClient = makeClient ?? { account in
            guard let credential = try await Task.detached(operation: {
                try KeychainCredentialStore().credential(accountID: account.id)
            }).value else {
                throw CollectivesError.signInRequired
            }
            return CollectivesClient(account: account, credential: credential)
        }
        session.windows.append(WeakAppWindow(self))
        textRuntime.warm()
    }
    func newWindow() -> AppModel {
        AppModel(store: store, session: session, preferences: preferences,
                 modePreferences: modePreferences, makeClient: makeClient)
    }
    var richTextInAnotherWindow: Bool {
        session.windows.contains { $0.value?.windowID != windowID && $0.value?.textSession != nil }
    }
    var editingInAnotherWindow: Bool {
        guard let accountID = activeID, let pageID = selectedPage?.id else { return false }
        return session.editorOwner(accountID: accountID, pageID: pageID).map { $0 != windowID } ?? false
    }
    private func claimEditor() -> Bool {
        guard let accountID = activeID, let pageID = selectedPage?.id else { return false }
        guard !editingInAnotherWindow else {
            message = "This page is being edited in another window. Switch that window to View to edit here."
            return false
        }
        session.editorOwners[AppSession.DocumentKey(accountID: accountID, pageID: pageID)] = windowID
        return true
    }
    private func releaseEditor() {
        session.editorOwners = session.editorOwners.filter { $0.value != windowID }
    }
    func refreshSharedSelection() {
        reconcileSelection()
        if activeID.map({ id in !accounts.contains(where: { $0.id == id }) }) == true {
            activeID = nil; selectedCollective = nil; selectedPage = nil; text = ""
        }
    }
    var account: Account? { accounts.first { $0.id == activeID } }
    var pages: [Page] { snapshot.pages[String(selectedCollective ?? -1)] ?? [] }
    var document: CachedDocument? { selectedPage.flatMap { snapshot.documents[String($0.id)] } }
    var pendingCount: Int { snapshot.documents.values.filter { $0.draft != nil }.count }
    var conflictCount: Int { snapshot.documents.values.filter { $0.conflict != nil }.count }
    var downloadedCount: Int { pages.filter { snapshot.documents[String($0.id)] != nil }.count }
    var canEdit: Bool { snapshot.collectives.first { $0.id == selectedCollective }?.canEdit == true }
    func syncSummary(now: Date = Date()) -> String {
        if savingDraft { return "Saving locally…" }
        if draftSaveFailed { return "Changes not saved" }
        if isCancellingSync { return "Cancelling sync…" }
        if let activity = syncActivity { return activity.summary }
        if syncing { return "Syncing…" }
        if let id = activeID, let issue = syncIssues[id] {
            return issue.requiresSignIn ? "Sign in to sync" : "Sync needs attention"
        }
        if conflictCount > 0 { return inflected("^[\(conflictCount) conflict](inflect: true) to review") }
        if automaticSyncPaused { return "Sync paused" }
        let state = pendingCount == 0 ? "Up to date" : inflected("^[\(pendingCount) draft](inflect: true) waiting to sync")
        guard let synced = activeID.flatMap({ lastSyncDates[$0] }) else { return state }
        let age = now.timeIntervalSince(synced) < 60 ? "just now"
            : synced.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\(state) · Synced \(age)"
    }
    var syncSymbol: String {
        if draftSaveFailed || conflictCount > 0 { return "exclamationmark.triangle" }
        if let id = activeID, syncIssues[id] != nil { return "exclamationmark.icloud" }
        if syncing { return "arrow.triangle.2.circlepath" }
        if savingDraft { return "externaldrive" }
        if automaticSyncPaused { return "pause.circle" }
        return pendingCount > 0 ? "pencil.circle" : "checkmark.icloud"
    }

    func start() async {
        guard !started else { return }; started = true
        defer { startupComplete = true }
        do {
            if !session.accountsLoaded {
                accounts = try await store.accounts()
                session.accountsLoaded = true
            }
            for account in accounts {
                do { accountCollectives[account.id] = try await snapshotForAccount(account.id).collectives }
                catch { collectiveListingErrors[account.id] = error.localizedDescription }
            }
            if let target = accounts.first(where: { $0.id == preferences.lastAccountID }) ?? accounts.first {
                while busy {
                    do { try await Task.sleep(for: .milliseconds(25)) }
                    catch { return }
                }
                await selectAccount(target.id, refresh: false)
                await restoreSelection()
                if pageMode != .richText && session.windows.compactMap(\.value).first(where: \.started) === self { await syncAccounts() }
            }
        } catch { message = CollectivesError.userMessage(for: error) }
    }
    func client() throws -> CollectivesClient {
        guard let account else { throw CollectivesError.noAccount }
        guard let client = cachedClients[account] else { throw CollectivesError.busy }
        return client
    }
    func activeClient() async throws -> CollectivesClient {
        guard let account else { throw CollectivesError.noAccount }
        return try await client(for: account)
    }
    func prepareReadingClient() async {
        _ = try? await activeClient()
    }
    private func client(for account: Account) async throws -> CollectivesClient {
        guard canSyncAccount(account.id) else { throw CancellationError() }
        if let client = cachedClients[account] { return client }
        let generation = clientGeneration
        let preparation = preparingClients[account] ?? ClientPreparation(task: Task { @MainActor [makeClient] in
            try await makeClient(account)
        })
        preparingClients[account] = preparation
        defer {
            if preparingClients[account]?.id == preparation.id { preparingClients[account] = nil }
        }
        let client = try await preparation.task.value
        guard clientGeneration == generation, canSyncAccount(account.id), accounts.contains(account) else { throw CancellationError() }
        cachedClients[account] = client
        return client
    }
    private func invalidateClient(accountID: UUID) {
        cachedClients = cachedClients.filter { $0.key.id != accountID }
        for account in preparingClients.keys.filter({ $0.id == accountID }) {
            preparingClients.removeValue(forKey: account)?.task.cancel()
        }
        clientGeneration = UUID()
    }
    func selectAccount(_ id: UUID, refresh: Bool = true) async {
        guard !busy, accounts.contains(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft successfully before switching accounts."; return }
        _ = await loadAccount(id, refresh: refresh)
    }
    private func loadAccount(_ id: UUID, refresh: Bool = true) async -> Bool {
        if let previousID = activeID { accountCollectives[previousID] = snapshot.collectives }
        let version = checkpointVersions[id, default: 0]
        let loaded: AccountSnapshot
        do {
            await pendingPersistence?.value
            if let current = session.snapshots[id] {
                loaded = current
            } else {
                let stored = try await store.snapshot(accountID: id)
                loaded = session.snapshots[id] ?? (checkpointVersions[id, default: 0] == version ? stored : checkpointSnapshots[id] ?? stored)
            }
        } catch { message = error.localizedDescription; return false }
        activeID = id; selectedCollective = nil; selectedPage = nil; text = ""
        snapshot = loaded
        accountCollectives[id] = loaded.collectives
        library = session.libraries[id] ?? preferences.load(accountID: id)
        preferences.lastAccountID = id
        guard refresh else { return true }
        do {
            guard let account else { throw CollectivesError.noAccount }
            let api = try await client(for: account)
            let remote = try await api.collectives()
            snapshot.replaceCollectives(remote)
            accountCollectives[id] = snapshot.collectives
            try await persist()
            collectiveListingErrors[id] = nil
        } catch {
            collectiveListingErrors[id] = CollectivesError.userMessage(for: error)
            syncIssues[id] = SyncIssue(error: error)
        }
        return true
    }
    func snapshotForAccount(_ id: UUID) async throws -> AccountSnapshot {
        if let cached = session.snapshots[id] { return cached }
        let stored = try await store.snapshot(accountID: id)
        return session.snapshots[id] ?? stored
    }
    func persist() async throws {
        guard let id = activeID else { return }
        try await store.saveSnapshot(snapshot, accountID: id)
    }
    func collectives(for accountID: UUID) -> [Collective] {
        accountID == activeID ? snapshot.collectives : accountCollectives[accountID] ?? []
    }
    @discardableResult
    func openCollective(_ id: Int, refresh: Bool = true) async -> Bool {
        guard !busy, snapshot.collectives.contains(where: { $0.id == id }) else { return false }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft before switching collectives."; return false }
        await loadCollective(id, refresh: refresh)
        return true
    }
    /// `onSelect` runs once the destination is selected, before its pages are refreshed from the server.
    func openSidebar(accountID: UUID, collectiveID: Int?, onSelect: () -> Void = {}) async -> Bool {
        guard !busy, accounts.contains(where: { $0.id == accountID }) else { return false }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft before switching pages."; return false }
        if activeID != accountID {
            guard await loadAccount(accountID) else { return false }
        }
        if let collectiveID {
            guard snapshot.collectives.contains(where: { $0.id == collectiveID }) else { return false }
            await loadCollective(collectiveID, onSelect: onSelect)
        } else {
            showHome()
            onSelect()
        }
        return true
    }
    private func loadCollective(_ id: Int, refresh: Bool = true, onSelect: () -> Void = {}) async {
        if selectedCollective != id {
            selectedCollective = id; selectedPage = nil; text = ""
            library.collectiveID = id; library.pageID = nil; saveLibrary()
        }
        onSelect()
        guard refresh else { return }
        do {
            snapshot.replacePages(try await activeClient().pages(collectiveID: id), collectiveID: id)
            reconcileSelection()
            try await persist()
        } catch {
            if let id = activeID { syncIssues[id] = SyncIssue(error: error) }
        }
    }
    /// Returns false when neither this page nor a page tapped while it was loading ended up open.
    @discardableResult
    func openPage(_ page: Page) async -> Bool {
        guard !busy else {
            if openingPage { queuedPage = page }
            return openingPage
        }
        if selectedPage?.id == page.id, document != nil, pageMode != .richText || !textRuntime.failed { return true }
        busy = true; openingPage = true; queuedPage = nil
        await finishTextEditing(retainingContent: pageMode == .richText)
        await pendingPersistence?.value
        var opened = false
        if persistenceFailed {
            message = "Save the current draft before switching pages."
        } else {
            opened = await loadPage(page)
        }
        await prepareTextEditing()
        busy = false; openingPage = false
        if let next = queuedPage {
            queuedPage = nil
            return await openPage(next)
        }
        return opened
    }
    @discardableResult
    private func loadPage(_ page: Page) async -> Bool {
        let key = String(page.id)
        if snapshot.documents[key] == nil {
            do {
                let body = try await activeClient().download(page: page)
                snapshot.documents[key] = CachedDocument(page: page, collectiveID: selectedCollective!, markdown: body.markdown, etag: body.etag)
                try await persist()
            } catch {
                message = "Could not open this page. \(CollectivesError.userMessage(for: error))"
                return false
            }
        }
        guard let cached = snapshot.documents[key] else { return false }
        selectedPage = page
        pageMode = modeForPage(hasConflict: cached.conflict != nil)
        if pageMode != .view && !claimEditor() { pageMode = .view }
        if let collectiveID = selectedCollective {
            library.visit(pageID: page.id, collectiveID: collectiveID); saveLibrary()
        }
        text = cached.draft ?? cached.markdown
        return true
    }
    func openDraft(_ pageID: Int) async {
        guard !busy else { return }
        if selectedPage?.id == pageID, document != nil, pageMode != .richText || !textRuntime.failed { return }
        busy = true; defer { busy = false }
        await finishTextEditing(retainingContent: pageMode == .richText)
        await pendingPersistence?.value
        if !persistenceFailed, let doc = snapshot.documents[String(pageID)] {
            selectedCollective = doc.collectiveID
            selectedPage = doc.page
            pageMode = modeForPage(hasConflict: doc.conflict != nil)
            if pageMode != .view && !claimEditor() { pageMode = .view }
            library.visit(pageID: doc.page.id, collectiveID: doc.collectiveID); saveLibrary()
            text = doc.draft ?? doc.markdown
        }
        await prepareTextEditing()
    }
    func edited(_ value: String, accountID: UUID?, pageID: Int, editorGeneration: UUID? = nil) {
        guard activeID == accountID, selectedPage?.id == pageID, pageMode == .edit,
              editorGeneration == nil || editorGeneration == sourceEditorGeneration else { return }
        edited(value)
    }
    func edited(_ value: String) {
        guard let page = selectedPage, let doc = snapshot.documents[String(page.id)], canEdit, !busy, textSession == nil, claimEditor() else { return }
        saveEdited(value, page: page, document: doc)
    }
    private func saveEdited(_ value: String, page: Page, document: CachedDocument) {
        var doc = document
        text = value
        lastEdit = Date()
        doc.draft = value == doc.markdown ? nil : value
        snapshot.documents[String(page.id)] = doc
        guard let id = activeID else { return }
        let saved = doc
        let generation = UUID()
        editGeneration = generation; savingDraft = true
        let previous = pendingPersistence
        pendingPersistence = Task {
            await previous?.value
            do {
                try await store.saveDocument(saved, accountID: id)
                if persistenceFailed {
                    for (accountID, snapshot) in session.snapshots where canSyncAccount(accountID) {
                        try await store.saveSnapshot(snapshot, accountID: accountID)
                    }
                }
                persistenceFailed = false
                if editGeneration == generation { savingDraft = false }
            } catch { savingDraft = false; persistenceFailed = true; message = "Draft not saved: \(error.localizedDescription)" }
        }
    }
    func modeForPage(hasConflict: Bool) -> PageViewMode {
        let preferred = modePreferences.modeForPage(canEdit: canEdit, hasConflict: hasConflict)
        return syncing && preferred == .richText ? .view : preferred
    }
    func resumeTextEditing() {
        guard !busy, document != nil else { return }
        if pageMode == .edit && !claimEditor() { pageMode = .view }
        guard pageMode == .richText, !syncing, textSession == nil else { return }
        Task { await beginTextEditing() }
    }
    func changePageMode(_ mode: PageViewMode) async {
        guard !busy, mode != pageMode else { return }
        guard mode != .richText || !syncing else {
            message = "Finish or cancel sync before opening Rich Text."
            return
        }
        guard mode == .view || claimEditor() else { return }
        busy = true
        await finishTextEditing()
        pageMode = !canEdit ? .view : (mode == .richText && document?.conflict != nil ? .edit : mode)
        if pageMode != .view && !claimEditor() { pageMode = .view }
        modePreferences.remember(mode)
        await prepareTextEditing()
        busy = false
    }
    func beginTextEditing() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await prepareTextEditing()
    }
    func prepareTextEditing() async {
        guard pageMode == .richText, !syncing, textSession == nil, canEdit,
              let accountID = activeID, let page = selectedPage,
              let document, document.conflict == nil, claimEditor() else { return }
        await pendingPersistence?.value
        guard !persistenceFailed else { pageMode = .edit; return }
        do {
            if snapshot.textSourceBackups?[String(page.id)] == nil {
                var next = snapshot
                next.rememberTextSource(pageID: page.id, markdown: text)
                try await store.saveSnapshot(next, accountID: accountID)
                snapshot = next
            }
            let session = EmbeddedTextSession(accountID: accountID, pageID: page.id, markdown: text)
            textSession = session
            textRuntime.start(session) { [weak self] revision, markdown in
                self?.textEdited(sessionID: session.id, revision: revision, markdown: markdown)
            }
        } catch {
            message = "Could not save the original source: \(error.localizedDescription)"
            pageMode = .edit
        }
    }
    func textEdited(sessionID: UUID, revision: Int, markdown: String) {
        guard var session = textSession, session.accountID == activeID,
              session.pageID == selectedPage?.id,
              session.accept(sessionID: sessionID, revision: revision),
              let page = selectedPage, let document else { return }
        textSession = session
        saveEdited(markdown, page: page, document: document)
    }
    func finishTextEditing(retainingContent: Bool = false) async {
        defer { releaseEditor() }
        await textRuntime.finish(retainingContent: retainingContent)
        guard textSession != nil else { return }
        await pendingPersistence?.value
        textSession = nil
    }
    func restoreTextSource() async {
        guard !busy else { return }
        busy = true
        await finishTextEditing()
        pageMode = .edit
        busy = false
        guard let page = selectedPage,
              let original = snapshot.textSourceBackups?[String(page.id)] else { return }
        edited(original)
    }
    var hasTextSourceBackup: Bool {
        selectedPage.flatMap { snapshot.textSourceBackups?[String($0.id)] } != nil
    }
    func syncLocalChanges() async {
        guard document?.hasLocalChanges == true else { return }
        await sync()
    }
    func sync() async {
        guard !busy, !syncing, pageMode != .richText, !session.hasRichTextEditor, let page = selectedPage, let target = account else { return }
        automaticSyncPaused = false
        syncing = true; defer { finishSync(); resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed, !isCancellingSync, activeID == target.id, selectedPage?.id == page.id,
              let doc = snapshot.documents[String(page.id)] else { return }
        guard doc.conflict == nil else { message = "Review the conflict before syncing."; return }
        let base = snapshot
        syncActivity = SyncActivity(account: target, accountIndex: 1, accountTotal: 1,
            progress: AccountSyncProgress(phase: doc.draft == nil ? .checking : .uploading,
                collective: snapshot.collectives.first { $0.id == doc.collectiveID }, page: page,
                totalPages: 1, totalCollectives: 1))
        do {
            try await performAccountSync(target.id) { [self] in
                let updated = try await DocumentSynchronizer.synchronize(document: doc, api: client(for: target))
                var next = base
                next.documents[String(page.id)] = updated
                if let activity = syncActivity {
                    var progress = activity.progress
                    progress.phase = .saving
                    syncActivity = SyncActivity(account: target, accountIndex: 1, accountTotal: 1, progress: progress)
                }
                try await applySync(next, startedFrom: base, accountID: target.id)
                try Task.checkCancellation()
                syncIssues[target.id] = nil
                if activeID == target.id, selectedPage?.id == page.id {
                    message = document?.conflict == nil ? "Page synced." : "The page changed on the server. Review your changes."
                }
            }
        } catch {
            if canSyncAccount(target.id), !isCancellingSync, !Task.isCancelled, !(error is CancellationError) {
                syncIssues[target.id] = SyncIssue(error: error)
            }
        }
        if isCancellingSync { await pendingPersistence?.value }
    }
    func downloadCollective() async {
        guard !session.hasRichTextEditor else { return }
        guard !busy, !syncing, let collectiveID = selectedCollective, let id = activeID else { return }
        automaticSyncPaused = false
        busy = true; defer { busy = false; finishSync(); resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed, !isCancellingSync, let target = account else { return }
        let previous = snapshot
        do {
            try await performAccountSync(id) { [self] in
                let localStore = store
                let result = try await AccountSynchronizer.download(collectiveID: collectiveID, snapshot: snapshot, api: activeClient(), progress: { progress in
                    await self.reportSyncProgress(progress, account: target, index: 1, total: 1)
                }) { value in
                    try Task.checkCancellation()
                    try await localStore.saveSnapshot(value, accountID: id)
                }
                try Task.checkCancellation()
                snapshot = result.snapshot
                reconcileSelection()
                message = result.failures.isEmpty
                    ? inflected("^[\(downloadedCount) page](inflect: true) available offline. Images and attachments stay online.")
                    : inflected("^[\(result.failures.count) page](inflect: true) could not be downloaded. Try again to finish.")
            }
        } catch {
            // Keep successful checkpoints if a later step fails or the user cancels.
            snapshot = (try? await store.snapshot(accountID: id)) ?? previous
            reconcileSelection()
            if !isCancellingSync {
                message = "Download incomplete. \(CollectivesError.userMessage(for: error))"
            }
        }
    }
    @discardableResult
    func syncAccounts(automatic: Bool = false) async -> Bool {
        guard !busy, !syncing, pageMode != .richText, !session.hasRichTextEditor, textSession == nil, !showLogin, !settingsLogin else { return false }
        if automatic && (automaticSyncPaused || Date().timeIntervalSince(lastEdit) < 5) { return false }
        if !automatic { automaticSyncPaused = false }
        syncing = true; defer { finishSync(); resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed, !isCancellingSync else { return false }
        let targets = automatic ? accounts.filter { $0.id == activeID } : accounts
        for target in targets {
            guard canSyncAccount(target.id) else { continue }
            if Task.isCancelled || isCancellingSync {
                await pendingPersistence?.value
                return false
            }
            do {
                try await performAccountSync(target.id) { [self] in
                    let base = try await snapshotForAccount(target.id)
                    let result = try await AccountSynchronizer.synchronize(snapshot: base, api: client(for: target), progress: { progress in
                        await self.reportSyncProgress(progress, account: target, targets: targets)
                    }) { value in
                        try await self.applySync(value, startedFrom: base, accountID: target.id)
                    }
                    try Task.checkCancellation()
                    guard canSyncAccount(target.id) else { throw CancellationError() }
                    collectiveListingErrors[target.id] = result.failures.first?.message
                    if let failure = result.failures.first {
                        syncIssues[target.id] = SyncIssue(message: failure.message,
                            requiresSignIn: result.failures.contains(where: \.requiresSignIn))
                    } else {
                        syncIssues[target.id] = nil
                        lastSyncDates[target.id] = Date()
                    }
                }
            } catch {
                if Task.isCancelled || isCancellingSync {
                    await pendingPersistence?.value
                    return false
                }
                guard canSyncAccount(target.id), !(error is CancellationError) else { continue }
                collectiveListingErrors[target.id] = CollectivesError.userMessage(for: error)
                syncIssues[target.id] = SyncIssue(error: error)
            }
        }
        if isCancellingSync { await pendingPersistence?.value }
        return !isCancellingSync
    }

    func cancelSync() {
        guard canCancelSync else { return }
        isCancellingSync = true
        automaticSyncPaused = true
        remoteSyncRequested = false
        for task in accountSyncTasks.values { task.cancel() }
    }
    private func finishSync() {
        if isCancellingSync && !persistenceFailed {
            message = "Sync canceled. Your pages and drafts are kept. Sync manually to turn automatic sync back on."
        }
        syncing = false
        syncActivity = nil
        syncBaselines = [:]
        isCancellingSync = false
    }

    private func canSyncAccount(_ id: UUID) -> Bool {
        accounts.contains { $0.id == id } && !removingAccountIDs.contains(id)
    }
    private func performAccountSync(_ id: UUID, operation: @escaping @MainActor () async throws -> Void) async throws {
        guard canSyncAccount(id), !isCancellingSync else { throw CancellationError() }
        let task = Task { @MainActor in
            try Task.checkCancellation()
            guard self.canSyncAccount(id), !self.isCancellingSync else { throw CancellationError() }
            try await operation()
        }
        accountSyncTasks[id] = task
        defer { accountSyncTasks[id] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
    private func reportSyncProgress(_ progress: AccountSyncProgress, account: Account, targets: [Account]) {
        let remaining = targets.filter { canSyncAccount($0.id) }
        guard let index = remaining.firstIndex(where: { $0.id == account.id }) else { return }
        reportSyncProgress(progress, account: account, index: index + 1, total: remaining.count)
    }
    private func reportSyncProgress(_ progress: AccountSyncProgress, account: Account, index: Int, total: Int) {
        guard canSyncAccount(account.id), !isCancellingSync else { return }
        syncActivity = SyncActivity(account: account, accountIndex: index, accountTotal: total, progress: progress)
    }

    private func applySync(_ remote: AccountSnapshot, startedFrom base: AccountSnapshot, accountID: UUID) async throws {
        // Flush local writes before reading an account that may no longer be active.
        await pendingPersistence?.value
        try Task.checkCancellation()
        guard canSyncAccount(accountID) else { throw CancellationError() }
        let current: AccountSnapshot
        if accountID == activeID { current = snapshot }
        else {
            let stored = try await store.snapshot(accountID: accountID)
            current = session.snapshots[accountID] ?? stored
        }
        try Task.checkCancellation()
        guard canSyncAccount(accountID) else { throw CancellationError() }
        let merged = current.mergingSync(remote, startedFrom: syncBaselines[accountID] ?? base)
        syncBaselines[accountID] = remote
        checkpointVersions[accountID, default: 0] += 1
        checkpointSnapshots[accountID] = merged
        accountCollectives[accountID] = merged.collectives
        session.snapshots[accountID] = merged
        session.refreshWindows(accountID: accountID)

        let previous = pendingPersistence
        let save = Task { @MainActor in
            await previous?.value
            guard self.canSyncAccount(accountID) else { throw CancellationError() }
            try await store.saveSnapshot(merged, accountID: accountID)
        }
        pendingPersistence = Task {
            do { try await save.value }
            catch {
                if canSyncAccount(accountID), !(error is CancellationError) {
                    persistenceFailed = true; message = "Draft not saved: \(error.localizedDescription)"
                }
            }
        }
        try await save.value
    }
    func reconcileSelection() {
        if let selected = selectedPage {
            selectedPage = snapshot.pages.values.joined().first { $0.id == selected.id }
                ?? snapshot.documents[String(selected.id)]?.page
            if selectedPage == nil { text = "" }
        }
        if let id = selectedCollective,
           !snapshot.collectives.contains(where: { $0.id == id }),
           selectedPage == nil { selectedCollective = nil }
        updateEditor()
    }
    func runAutomaticSync() async {
        guard let target = account else { return }
        let generation = UUID()
        automaticSyncGeneration = generation
        pushConnected = false
        defer {
            if automaticSyncGeneration == generation {
                automaticSyncGeneration = nil
                pushConnected = false
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.listenForChanges(account: target, generation: generation) }
            var lastRefresh = Date.distantPast
            var lastDraftSync = Date.distantPast
            while !Task.isCancelled && automaticSyncGeneration == generation {
                let now = Date()
                let interval: TimeInterval = pushConnected ? 15 * 60 : 60
                if !automaticSyncPaused && (remoteSyncRequested || now.timeIntervalSince(lastRefresh) >= interval) {
                    // Clear first so a push arriving during the request schedules another pass.
                    remoteSyncRequested = false
                    if await syncAccounts(automatic: true) { lastRefresh = now; lastDraftSync = now }
                    else { remoteSyncRequested = true }
                } else if !automaticSyncPaused && now.timeIntervalSince(lastDraftSync) >= 30 {
                    await syncPending(automatic: true)
                    lastDraftSync = now
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
            group.cancelAll()
        }
    }
    private func listenForChanges(account target: Account, generation: UUID) async {
        while !Task.isCancelled && automaticSyncGeneration == generation {
            do {
                let api = try await client(for: target)
                guard let endpoint = try await api.notifyPushEndpoint() else { return }
                let credentialStore = credentials
                guard let credential = try await Task.detached(operation: {
                    try credentialStore.credential(accountID: target.id)
                }).value else { return }
                let sessions = NotifyPushSessions(client: api)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            try await NotifyPushListener.listen(endpoint: endpoint, account: target, credential: credential,
                                onAuthenticated: {
                                    await self.pushAuthenticated(sessions: sessions, generation: generation)
                                }, onChange: {
                                    await self.requestRemoteSync(generation: generation)
                                })
                        } catch { }
                    }
                    group.addTask { await self.maintainPushSessions(sessions, generation: generation) }
                    await group.next()
                    group.cancelAll()
                }
                if automaticSyncGeneration == generation { pushConnected = false }
                await sessions.close()
            } catch {
                if automaticSyncGeneration == generation { pushConnected = false }
            }
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
        }
    }
    private func requestRemoteSync(generation: UUID) {
        if automaticSyncGeneration == generation { remoteSyncRequested = true }
    }
    private func pushAuthenticated(sessions: NotifyPushSessions, generation: UUID) async {
        guard automaticSyncGeneration == generation else { return }
        remoteSyncRequested = true
        do {
            try await sessions.refresh(collectiveIDs: snapshot.collectives.map(\.id))
            if automaticSyncGeneration == generation { pushConnected = true }
        } catch {
            if automaticSyncGeneration == generation { pushConnected = false }
        }
    }
    private func maintainPushSessions(_ sessions: NotifyPushSessions, generation: UUID) async {
        while !Task.isCancelled && automaticSyncGeneration == generation {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            do { try await sessions.refresh(collectiveIDs: snapshot.collectives.map(\.id)) }
            catch {
                if automaticSyncGeneration == generation { pushConnected = false }
                return
            }
        }
    }
    func syncPending(automatic: Bool = false) async {
        guard !busy, !syncing, pageMode != .richText, !session.hasRichTextEditor, textSession == nil, !showLogin, !settingsLogin else { return }
        if automatic {
            guard !automaticSyncPaused, Date().timeIntervalSince(lastEdit) >= 5,
                  snapshot.documents.values.contains(where: { $0.draft != nil && $0.conflict == nil }) else { return }
        }
        if !automatic { automaticSyncPaused = false }
        syncing = true; defer { finishSync(); resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed, !isCancellingSync else { return }
        let targets = automatic ? accounts.filter { $0.id == activeID } : accounts
        for target in targets {
            if isCancellingSync || Task.isCancelled {
                await pendingPersistence?.value
                return
            }
            guard canSyncAccount(target.id) else { continue }
            do {
                try await performAccountSync(target.id) { [self] in
                    let base = try await snapshotForAccount(target.id)
                    let result = try await AccountSynchronizer.synchronizeDrafts(snapshot: base, api: client(for: target), progress: { progress in
                        await self.reportSyncProgress(progress, account: target, targets: targets)
                    }) { value in
                        try await self.applySync(value, startedFrom: base, accountID: target.id)
                    }
                    try Task.checkCancellation()
                    guard canSyncAccount(target.id) else { throw CancellationError() }
                    if let failure = result.failures.first {
                        syncIssues[target.id] = SyncIssue(message: failure.message,
                            requiresSignIn: result.failures.contains(where: \.requiresSignIn))
                    }
                    // Draft-only sync cannot establish that a previous account refresh error has recovered.
                }
            } catch {
                if Task.isCancelled || isCancellingSync {
                    await pendingPersistence?.value
                    return
                }
                guard canSyncAccount(target.id), !(error is CancellationError) else { continue }
                syncIssues[target.id] = SyncIssue(error: error)
            }
        }
        if isCancellingSync { await pendingPersistence?.value }
    }
    private func updateEditor() {
        if let doc = document { text = doc.draft ?? doc.markdown }
    }
    func resolveConflict(useServer: Bool) async {
        guard !busy, !syncing, let page = selectedPage, var doc = document, let remote = doc.conflict else { return }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        let local = doc.draft ?? text
        doc.markdown = remote.markdown; doc.etag = remote.etag
        doc.draft = useServer ? nil : local; doc.conflict = nil
        var next = snapshot
        next.documents[String(page.id)] = doc
        do {
            guard let id = activeID else { return }
            try await store.saveSnapshot(next, accountID: id)
            snapshot = next; text = doc.draft ?? doc.markdown
            message = useServer ? "Kept the server version." : "Kept your version. It syncs next."
        } catch { message = CollectivesError.userMessage(for: error) }
    }
    func beginLogin(server: URL? = nil) {
        loginServer = server?.absoluteString ?? "https://"
        showLogin = true
    }
    func accountBackup(_ id: UUID) async throws -> String {
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.draftNotSaved }
        let saved = try await store.snapshot(accountID: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(saved), as: UTF8.self)
    }
    func removeAccount(_ id: UUID) async throws {
        guard !richTextInAnotherWindow else { throw CollectivesError.richTextOpenElsewhere }
        guard !busy, accounts.contains(where: { $0.id == id }) else { throw CollectivesError.busy }
        busy = true
        defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.draftNotSaved }
        let saved = id == activeID ? snapshot : try await store.snapshot(accountID: id)
        guard !saved.documents.values.contains(where: \.hasLocalChanges) else { throw AccountRemovalError.unsyncedChanges }
        removingAccountIDs.insert(id)
        defer { removingAccountIDs.remove(id) }
        accountSyncTasks[id]?.cancel()
        if syncActivity?.account.id == id { syncActivity = nil }
        let credentialStore = credentials
        try await store.removeAccount(accountID: id) { try credentialStore.remove(accountID: $0) }
        invalidateClient(accountID: id)
        accounts.removeAll { $0.id == id }
        session.snapshots[id] = nil
        session.refreshWindows(accountID: id, except: windowID)
        if let activity = syncActivity, activity.accountTotal > 1 {
            reportSyncProgress(activity.progress, account: activity.account, targets: accounts)
        }
        accountCollectives[id] = nil
        collectiveListingErrors[id] = nil
        invalidateClient(accountID: id)
        checkpointSnapshots[id] = nil; checkpointVersions[id] = nil
        syncBaselines[id] = nil
        syncIssues[id] = nil
        lastSyncDates[id] = nil
        preferences.remove(accountID: id)
        session.libraries[id] = nil
        if activeID == id {
            automaticSyncGeneration = nil; pushConnected = false; remoteSyncRequested = false
            activeID = nil; snapshot = AccountSnapshot()
            selectedCollective = nil; selectedPage = nil; text = ""
            if let first = accounts.first { _ = await loadAccount(first.id, refresh: false) }
        }
        message = "Account removed from this device."
    }
    func saveLibrary() {
        if let id = activeID { preferences.save(library, accountID: id) }
    }
    private func restoreSelection() async {
        var saved = library
        var launchPageMissing = false
        switch saved.launchPage {
        case .home:
            showHome(); return
        case .page(let pageID):
            if let collectiveID = collectiveID(for: pageID) {
                saved.collectiveID = collectiveID; saved.pageID = pageID
            } else {
                launchPageMissing = true
            }
        case nil: break
        }
        defer { if launchPageMissing { message = "Your start page is no longer available." } }
        guard let collectiveID = saved.collectiveID,
              snapshot.collectives.contains(where: { $0.id == collectiveID }) else { return }
        if await openCollective(collectiveID, refresh: false), let pageID = saved.pageID {
            if let page = pages.first(where: { $0.id == pageID }) { await openPage(page) }
            else if snapshot.documents[String(pageID)]?.draft != nil { await openDraft(pageID) }
        }
    }
    private func showHome() {
        selectedCollective = nil; selectedPage = nil; text = ""
        library.collectiveID = nil; library.pageID = nil; saveLibrary()
    }
    func toggleFavorite(_ pageID: Int) {
        library.toggleFavorite(pageID); saveLibrary()
    }
    func toggleLaunchPage(_ pageID: Int) {
        library.toggleLaunchPage(pageID); saveLibrary()
    }
    func launchPage(accountID: UUID) -> LaunchPage? {
        (session.libraries[accountID] ?? preferences.load(accountID: accountID)).launchPage
    }
    func setLaunchPage(_ launchPage: LaunchPage?, accountID: UUID) {
        var state = session.libraries[accountID] ?? preferences.load(accountID: accountID)
        state.launchPage = launchPage
        session.libraries[accountID] = state
        preferences.save(state, accountID: accountID)
    }
    func pageTitle(_ pageID: Int, accountID: UUID) -> String? {
        guard let snapshot = session.snapshots[accountID] else { return nil }
        return snapshot.documents[String(pageID)]?.page.title
            ?? snapshot.pages.values.lazy.flatMap { $0 }.first { $0.id == pageID }?.title
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
    func openQuickSearchResult(_ result: PageQuickSearchResult, accountID: UUID) async -> Bool {
        guard !busy, activeID == accountID else { return false }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing(retainingContent: pageMode == .richText)
        await pendingPersistence?.value
        guard !persistenceFailed else {
            message = "Save the current draft before switching pages."
            return false
        }
        guard let current = PageQuickSearch.results(in: snapshot, query: "").first(where: {
            $0.id == result.id && $0.collectiveID == result.collectiveID
        }) else { return false }
        selectedCollective = current.collectiveID
        await loadPage(current.page)
        return true
    }
    func setEmoji(_ emoji: String?) async throws {
        guard !richTextInAnotherWindow else { throw CollectivesError.richTextOpenElsewhere }
        guard !busy, !syncing, canEdit, let page = selectedPage, let collectiveID = selectedCollective,
              let accountID = activeID else { throw CollectivesError.busy }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.draftNotSaved }
        let updated = try await activeClient().setPageEmoji(pageID: page.id, collectiveID: collectiveID, emoji: emoji)
        var next = snapshot
        next.pages[String(collectiveID)] = (next.pages[String(collectiveID)] ?? []).map { $0.id == page.id ? updated : $0 }
        if var cached = next.documents[String(page.id)] { cached.page = updated; next.documents[String(page.id)] = cached }
        try await store.saveSnapshot(next, accountID: accountID)
        snapshot = next; selectedPage = updated
    }
    func createPage(title: String, parentID: Int, collectiveID: Int, accountID: UUID) async throws {
        guard !richTextInAnotherWindow else { throw CollectivesError.richTextOpenElsewhere }
        guard !busy, !syncing, activeID == accountID, selectedCollective == collectiveID, canEdit else {
            throw CollectivesError.busy
        }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed else { throw PageCreationError.unsavedDraft }
        let result = try await PageCreator.create(title: title, parentID: parentID, collectiveID: collectiveID,
            snapshot: snapshot, api: activeClient())
        let previous = snapshot
        snapshot = result.snapshot
        selectedPage = result.page
        pageMode = modePreferences.modeForNewPage(canEdit: canEdit)
        if pageMode != .view && !claimEditor() { pageMode = .view }
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
    func renamePage(title: String, pageID: Int, collectiveID: Int, accountID: UUID) async throws {
        guard !richTextInAnotherWindow else { throw CollectivesError.richTextOpenElsewhere }
        guard !busy, !syncing, activeID == accountID, selectedCollective == collectiveID, canEdit else {
            throw CollectivesError.busy
        }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed else { throw PageRenamingError.unsavedDraft }
        let result = try await PageRenamer.rename(title: title, pageID: pageID, collectiveID: collectiveID,
            snapshot: snapshot, api: activeClient())
        snapshot = result.snapshot
        if let selected = selectedPage {
            selectedPage = pages.first(where: { $0.id == selected.id }) ?? snapshot.documents[String(selected.id)]?.page ?? selected
        }
        do {
            try await persist()
            message = (["Page renamed on the server."] + result.warnings).joined(separator: " ")
        } catch {
            message = "Page renamed on the server, but updated paths could not be saved locally. Refresh pages when storage is available. \(error.localizedDescription)"
        }
    }
    func addAccount(_ login: LoginCredentials) async throws {
        guard !richTextInAnotherWindow else { throw CollectivesError.richTextOpenElsewhere }
        guard !busy, !syncing else { throw CollectivesError.busy }
        busy = true; defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.draftNotSaved }
        let credential = Credential(loginName: login.loginName, appPassword: login.appPassword)
        let server = try ServerAddress.normalize(login.server)
        let provisional = Account(serverURL: server, userID: login.loginName)
        let userID = try await CollectivesClient(account: provisional, credential: credential).currentUserID()
        try Task.checkCancellation()
        let existing = accounts.first { $0.serverURL == server && $0.userID == userID }
        let new = Account(id: existing?.id ?? UUID(), serverURL: server, userID: userID)
        let credentialStore = credentials
        try await Task.detached {
            try credentialStore.save(credential, accountID: new.id)
        }.value
        invalidateClient(accountID: new.id)
        syncIssues[new.id] = nil
        if existing == nil { accounts.append(new) }
        try await store.saveAccounts(accounts)
        busy = false
        await selectAccount(new.id)
        await syncAccounts(automatic: true)
    }
}

/// Resolves `^[\(n) page](inflect: true)` markup into a plain string.
func inflected(_ value: String.LocalizationValue) -> String {
    String(AttributedString(localized: value).characters)
}

/// iPhone: a list keeps its row highlighted only while a later column is pushed.
enum CompactNavigation {
    private static let order: [NavigationSplitViewColumn] = [.sidebar, .content, .detail]
    static func showsSelection(of list: NavigationSplitViewColumn, at column: NavigationSplitViewColumn) -> Bool {
        (order.firstIndex(of: column) ?? 0) > (order.firstIndex(of: list) ?? 0)
    }
}

private struct SidebarDestination: Hashable {
    let accountID: UUID
    let collectiveID: Int?
}

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("automaticSync") private var automaticSync = true
    @State private var search = ""
    @AppStorage("closeSidebarAfterCollectiveSwitch") private var closeSidebarAfterCollectiveSwitch = false
    @State private var showCommandPalette = false
    @State private var showSettings = false
    @State private var showSyncIssue = false
    @State private var newPageRequest: NewPageRequest?
    @State private var renamePageRequest: RenamePageRequest?
    @State private var pageOrganizationRequest: PageOrganizationRequest?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var homeColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingOutline = false
    @State private var confirmRestoreText = false
    @State private var showingFind = false
    @State private var conflictReview: ConflictReviewRequest?
    @State private var showActivity = false
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    #if os(macOS)
    private let compact = false
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #endif
    var body: some View {
        Group {
            if model.selectedCollective == nil && !compact {
                NavigationSplitView(columnVisibility: $homeColumnVisibility, preferredCompactColumn: $compactColumn) {
                    accountSidebar
                } detail: {
                    detailContent
                        .navigationTitle("Home")
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
                    accountSidebar
                } content: {
                    if model.selectedCollective == nil {
                        LibraryHomeView(model: model) { compactColumn = .detail }.navigationTitle("Home")
                    } else {
                        pageList
                    }
                } detail: {
                    detailContent
                }
            }
        }
        .onChange(of: model.startupComplete) {
            guard compact, model.startupComplete, compactColumn == .sidebar, model.activeID != nil else { return }
            compactColumn = model.selectedPage == nil ? .content : .detail
        }
        .task(id: model.busy) {
            showActivity = false
            guard model.busy else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            if model.busy { showActivity = true }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Go to Page…", systemImage: "doc.text.magnifyingglass") { showCommandPalette = true }
                    .help("Search all synced pages (⌘K)")
                    .disabled(model.busy || model.account == nil)
                    #if !os(macOS)
                    .keyboardShortcut("k", modifiers: .command)
                    #endif
            }
        }
        #if os(macOS)
        .focusedSceneValue(\.commandPalette, model.account != nil && !model.busy ? $showCommandPalette : nil)
        .focusedSceneValue(\.pageCommandActions, pageCommandActions)
        .toolbarBackground(AppSurface.chrome, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        #endif
        .alert("Restore Original Source?", isPresented: $confirmRestoreText) {
            Button("Restore Source", role: .destructive) { Task { await model.restoreTextSource() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current draft with the source saved before the first Text editing session. It will sync like a normal Markdown edit.")
        }
        .sheet(isPresented: $showCommandPalette) {
            if let accountID = model.activeID {
                CommandPaletteView(model: model, accountID: accountID) {
                    search = ""; compactColumn = .detail
                }
            }
        }
        .sheet(item: $newPageRequest) { request in
            NewPageSheet(model: model, request: request) {
                search = ""; compactColumn = .detail
            }
        }
        .sheet(item: $renamePageRequest) { request in RenamePageSheet(model: model, request: request) }
        .sheet(item: $pageOrganizationRequest) { request in PageOrganizationSheet(model: model, request: request) }
        .sheet(item: $conflictReview) { review in
            ConflictReviewSheet(model: model, review: review)
        }
        .sheet(isPresented: $model.showLogin) { LoginView(model: model) }
        #if !os(macOS)
        .sheet(isPresented: $showSettings) { AppSettingsView(model: model) }
        #endif

    }
    private var accountSidebar: some View {
        VStack(spacing: 0) {
            sidebarList
            sidebarFooter
        }
        .background(AppSurface.chrome)
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        .navigationTitle("Collectives")
    }
    private var pageList: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            PageSearchField(text: $search)
                .padding(.horizontal, 12).padding(.vertical, 10)
            #endif
            if model.selectedCollective == nil {
                ContentUnavailableView("Choose a Collective", systemImage: "books.vertical")
            } else if !search.isEmpty && searchResults.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if search.isEmpty && model.pages.isEmpty && model.busy {
                ProgressView("Loading pages…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.isEmpty && model.pages.isEmpty {
                ContentUnavailableView {
                    Label("No Pages", systemImage: "doc.text")
                } description: {
                    Text("Refresh to load this collective's pages. New pages are added below its landing page.")
                } actions: {
                    Button("Refresh") { refreshPages() }
                }
            } else {
                List(selection: pageSelection) {
                    if search.isEmpty {
                        if let accountID = model.activeID, let collectiveID = model.selectedCollective {
                            RememberedPageOutline(nodes: visibleTree, accountID: accountID,
                                collectiveID: collectiveID, selectedPageID: model.selectedPage?.id) { node in
                                pageRow(node.page, hasChildren: node.children != nil)
                            }
                        }
                    } else {
                        ForEach(searchResults) { page in
                            NavigationLink(value: page.id) {
                                VStack(alignment: .leading, spacing: 3) {
                                    pageRow(page, hasChildren: false)
                                    Text(pagePath(page).map { $0.title }.joined(separator: " › "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                #if os(macOS)
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                #else
                .listStyle(.insetGrouped)
                .refreshable { await refreshPagesNow() }
                #endif
            }
            #if os(macOS)
            if model.selectedCollective != nil {
                HStack {
                    Label("^[\(model.pages.count) page](inflect: true)", systemImage: "doc.text")
                    Spacer()
                    Text("\(model.downloadedCount) offline")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            #endif
        }
        .background(AppSurface.chrome)
        #if !os(macOS)
        .searchable(text: $search, prompt: "Search pages")
        .toolbar {
            if model.selectedCollective != nil {
                ToolbarItem(placement: .status) {
                    Group {
                        if model.undoableTrash != nil {
                            Button("Undo Move to Trash") { Task { await model.undoTrash() } }
                        } else if model.downloadedCount == model.pages.count {
                            Text("^[\(model.pages.count) page](inflect: true), all offline")
                        } else {
                            Text("^[\(model.pages.count) page](inflect: true), \(model.downloadedCount) offline")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        #endif
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 440)
        .navigationTitle(collectiveTitle)
        .toolbar {
            Button("New Page", systemImage: "square.and.pencil") { beginNewPage() }
                #if !os(macOS)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                #endif
                .disabled(!canCreatePage)
            Menu {
                Button("New Page…", systemImage: "doc.badge.plus") { beginNewPage() }
                    .disabled(!model.canEdit || model.pages.isEmpty)
                Button("Rename Page…", systemImage: "pencil") {
                    if let page = organizablePage { beginRename(page) }
                }.disabled(organizablePage == nil)
                Button("Move Page…", systemImage: "folder") {
                    if let page = organizablePage { beginPageOrganization(.move(page)) }
                }.disabled(organizablePage == nil)
                Button("Move Page to Trash…", systemImage: "trash", role: .destructive) {
                    if let page = organizablePage { beginPageOrganization(.trash(page)) }
                }.disabled(organizablePage == nil)
                if let pageID = model.selectedPage?.id { launchPageToggle(pageID) }
                Button("Deleted Pages…", systemImage: "arrow.uturn.backward") { beginPageOrganization(.restore) }
                    .disabled(!model.canEdit)
                Button("Download for Offline Editing", systemImage: "arrow.down.circle") { Task { await model.downloadCollective() } }
                Button("Refresh Pages", systemImage: "arrow.clockwise") { refreshPages() }
                if model.hasTextSourceBackup {
                    Button("Restore Source from Before Text Editing…", systemImage: "clock.arrow.circlepath") { confirmRestoreText = true }
                }
            } label: { Label("Collective Actions", systemImage: "ellipsis.circle") }
                .disabled(model.busy || model.syncing || model.selectedCollective == nil)
        }
    }
    private func sourceEditorBinding(page: Page) -> Binding<String> {
        let accountID = model.activeID
        let generation = model.sourceEditorGeneration
        return Binding(get: { model.text }, set: { value in
            model.edited(value, accountID: accountID, pageID: page.id, editorGeneration: generation)
        })
    }
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let page = model.selectedPage, model.document != nil {
                #if !os(macOS)
                pageModePicker
                #endif
                HStack(spacing: 5) {
                    if let landing = model.pages.first(where: { $0.parentId == 0 }) {
                        breadcrumbButton(collectiveTitle, page: landing)
                    } else {
                        Text(collectiveTitle)
                    }
                    ForEach(pagePath(page)) { ancestor in
                        breadcrumbChevron
                        breadcrumbButton(ancestor.title, page: ancestor)
                    }
                    breadcrumbChevron
                    Text(page.title).fontWeight(.medium).foregroundStyle(.primary)
                        .layoutPriority(1)
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if model.editingInAnotherWindow {
                    Label("Editing in another window. Switch that window to View to edit here.", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal)
                }
                if model.pageMode == .richText && model.canEdit && model.document?.conflict == nil {
                    editingHeader(page)
                    OfflineTextPage(runtime: model.textRuntime)
                        #if !os(macOS)
                        .padding(.horizontal, -detailInset)
                        #endif
                } else if model.pageMode == .edit && model.canEdit {
                    editingHeader(page)
                    MarkdownSourceEditor(text: sourceEditorBinding(page: page), disabled: model.busy || model.editingInAnotherWindow,
                                         showingFind: $showingFind, focusOnAppear: model.text.isEmpty)
                        .id(pageIdentity)
                } else {
                    MarkdownReader(showingOutline: $showingOutline, showingFind: $showingFind, model: model, source: model.text, page: page, account: model.account,
                        pages: model.pages, client: try? model.client()) { destination in
                            Task { await model.openPage(destination) }
                        }
                        .id("\(model.activeID?.uuidString ?? "")/\(page.id)")
                        .task(id: model.activeID) { await model.prepareReadingClient() }
                }
                if model.document?.conflict != nil {
                    HStack {
                        Label("This page has conflicting changes.", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Review Changes…") { conflictReview = ConflictReviewRequest(model: model) }
                            .disabled(model.busy || model.syncing)
                    }
                    .padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
            #if os(macOS)
            statusLine
            #endif
        }
        #if os(macOS)
        .padding()
        #else
        .padding(.horizontal, detailInset)
        .padding(.vertical, 8)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurface.document)
        #if !os(macOS)
        .toolbar {
            if !model.message.isEmpty || model.busy && showActivity {
                ToolbarItem(placement: .status) { statusLine }
            }
        }
        #endif
        .toolbar {
            if model.selectedPage != nil, model.document != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    #if os(macOS)
                    pageModePicker.frame(width: 250)
                    #endif
                    ShareLink("Share Markdown", item: model.text)
                        .labelStyle(.iconOnly).help("Share Markdown source")
                    Button(model.document?.draft == nil ? "Reload Page" : "Sync Page",
                           systemImage: model.document?.draft == nil ? "arrow.clockwise" : "arrow.triangle.2.circlepath") {
                        Task { await model.sync() }
                    }
                    .labelStyle(.iconOnly)
                    .help(model.pageMode == .richText ? "Switch to View or Edit to sync" : (model.document?.draft == nil ? "Reload page from server" : "Sync page, preserving conflicting edits"))
                    .disabled(model.busy || model.syncing || model.pageMode == .richText)
                }
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) { Spacer() }
                #endif
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.pageMode == .view {
                        Button { showingOutline.toggle() } label: {
                            Label("Table of Contents", systemImage: "list.bullet.indent")
                        }
                        .labelStyle(.iconOnly)
                        .help(showingOutline ? "Hide table of contents" : "Show table of contents")
                        .accessibilityValue(showingOutline ? "Shown" : "Hidden")
                    }
                    Button {
                        if model.pageMode == .richText { Task { await model.changePageMode(.view); showingFind = true } }
                        else { showingFind = true }
                    } label: { Label("Find in Page", systemImage: "magnifyingglass") }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Find in page (⌘F)")
                }
            }
        }
    }
    private func editingHeader(_ page: Page) -> some View {
        DocumentHeader(model: model, page: page, compact: compact)
            .frame(maxWidth: 740).frame(maxWidth: .infinity)
            .padding(.horizontal, documentInset)
    }
    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.undoableTrash != nil {
                Button("Undo") { Task { await model.undoTrash() } }.controlSize(.small)
            }
            ProgressView().controlSize(.small)
                .frame(width: 16, height: 16)
                .opacity(model.busy && showActivity ? 1 : 0)
                .accessibilityHidden(!model.busy || !showActivity)
        }
    }
    private var pageModePicker: some View {
        Picker("Page Mode", selection: Binding(get: { model.pageMode }, set: { mode in
            Task { await model.changePageMode(mode) }
        })) {
            ForEach(PageViewMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .disabled(model.busy || !model.canEdit)
    }
    private var breadcrumbChevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
    }
    private func breadcrumbButton(_ title: String, page: Page) -> some View {
        Button(title) { Task { await model.openPage(page) } }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
    private var canCreatePage: Bool { !model.busy && !model.syncing && model.canEdit && !model.pages.isEmpty }
    private var organizablePage: Page? {
        guard !model.busy, !model.syncing, model.canEdit, let page = model.selectedPage, page.parentId != 0 else { return nil }
        return page
    }
    #if os(macOS)
    private var pageCommandActions: PageCommandActions {
        let page = organizablePage
        let idle = !model.busy && !model.syncing && model.selectedCollective != nil
        return PageCommandActions(
            newPage: canCreatePage ? { beginNewPage() } : nil,
            rename: page.map { page in { beginRename(page) } },
            move: page.map { page in { beginPageOrganization(.move(page)) } },
            trash: page.map { page in { beginPageOrganization(.trash(page)) } },
            restoreSource: model.hasTextSourceBackup && !model.busy ? { confirmRestoreText = true } : nil,
            refreshPages: idle ? { refreshPages() } : nil)
    }
    #endif
    private func refreshPages() { Task { await refreshPagesNow() } }
    private func refreshPagesNow() async {
        if let id = model.selectedCollective { await model.openCollective(id) }
    }
    private func favoriteButton(_ pageID: Int) -> some View {
        Button(model.library.favoritePageIDs.contains(pageID) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") { model.toggleFavorite(pageID) }
    }
    private func launchPageToggle(_ pageID: Int) -> some View {
        Toggle("Open at Launch", systemImage: "power", isOn: Binding(
            get: { model.library.launchPage == .page(pageID) },
            set: { _ in model.toggleLaunchPage(pageID) }))
    }
    private let detailInset: CGFloat = 16
    private var documentInset: CGFloat {
        #if os(macOS)
        28
        #else
        4
        #endif
    }
    private func beginNewPage(parent: Page? = nil) {
        guard !model.busy, model.canEdit, let accountID = model.activeID,
              let collectiveID = model.selectedCollective,
              let parent = parent ?? model.pages.first(where: { $0.parentId == 0 }) else { return }
        newPageRequest = NewPageRequest(accountID: accountID, collectiveID: collectiveID,
            collectiveName: collectiveTitle, parentID: parent.id)
    }
    private func beginRename(_ page: Page) {
        guard !model.busy, model.canEdit, page.parentId != 0,
              let accountID = model.activeID, let collectiveID = model.selectedCollective else { return }
        renamePageRequest = RenamePageRequest(accountID: accountID, collectiveID: collectiveID, page: page)
    }
    private func beginPageOrganization(_ action: PageOrganizationRequest.Action) {
        guard !model.busy, !model.syncing, model.canEdit,
              let accountID = model.activeID, let collectiveID = model.selectedCollective else { return }
        pageOrganizationRequest = PageOrganizationRequest(accountID: accountID, collectiveID: collectiveID, action: action)
    }
    private var pageIdentity: String { "\(model.activeID?.uuidString ?? "")/\(model.selectedPage?.id.description ?? "")" }
    private func append(_ snippet: String) { model.edited(model.text + snippet) }
    private var collectiveTitle: String {
        model.snapshot.collectives.first { $0.id == model.selectedCollective }?.name ?? "Pages"
    }
    private var drafts: [CachedDocument] {
        model.snapshot.documents.values.filter { $0.draft != nil }.sorted { $0.page.title.localizedStandardCompare($1.page.title) == .orderedAscending }
    }
    private var collectiveSelection: Binding<SidebarDestination?> {
        Binding(get: {
            if compact && !CompactNavigation.showsSelection(of: .sidebar, at: compactColumn) { return nil }
            return model.activeID.map { SidebarDestination(accountID: $0, collectiveID: model.selectedCollective) }
        }, set: { destination in
            guard let destination else { return }
            Task {
                guard await model.waitForNavigationTurn() else { return }
                let previous = model.activeID.map {
                    SidebarDestination(accountID: $0, collectiveID: model.selectedCollective)
                }
                guard await model.openSidebar(accountID: destination.accountID, collectiveID: destination.collectiveID, onSelect: {
                    search = ""
                    if compact { compactColumn = .content }
                }) else { return }
                if compact { return }
                if destination.collectiveID == nil { compactColumn = .detail }
                else if previous?.collectiveID == nil {
                    columnVisibility = closeSidebarAfterCollectiveSwitch ? .doubleColumn : .all
                    compactColumn = .content
                } else if previous != destination && closeSidebarAfterCollectiveSwitch {
                    columnVisibility = .doubleColumn
                    compactColumn = .content
                }
            }
        })
    }
    private var pageSelection: Binding<Int?> {
        Binding(get: { compact && !CompactNavigation.showsSelection(of: .content, at: compactColumn) ? nil : model.selectedPage?.id }, set: { id in
            guard let page = model.pages.first(where: { $0.id == id }) else { return }
            if compact { compactColumn = .detail }
            Task {
                guard await model.waitForNavigationTurn(openingPage: true) else { return }
                if await !model.openPage(page) && compact { compactColumn = .content }
            }
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
            favoriteButton(page.id)
            launchPageToggle(page.id)
            Button("Open Page", systemImage: "doc.text") { Task { await model.openPage(page) } }
            Button("Rename…", systemImage: "pencil") { beginRename(page) }
                .disabled(model.busy || model.syncing || !model.canEdit || page.parentId == 0)
            Button("Move…", systemImage: "folder") { beginPageOrganization(.move(page)) }
                .disabled(model.busy || model.syncing || !model.canEdit || page.parentId == 0)
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { beginPageOrganization(.trash(page)) }
                .disabled(model.busy || model.syncing || !model.canEdit || page.parentId == 0)
            Button("New Subpage…", systemImage: "doc.badge.plus") { beginNewPage(parent: page) }
                .disabled(model.busy || model.syncing || !model.canEdit)
        }
        .swipeActions(edge: .leading) { favoriteButton(page.id).tint(.yellow) }
        .swipeActions(edge: .trailing) {
            if model.canEdit && page.parentId != 0 {
                Button("Move to Trash…", systemImage: "trash") { beginPageOrganization(.trash(page)) }.tint(.red)
            }
        }
        .help(([collectiveTitle] + pagePath(page).map { $0.title } + [page.title]).joined(separator: " › "))
    }
    private var sidebarList: some View {
        List(selection: collectiveSelection) {
            ForEach(model.accounts) { account in
                Section {
                    #if os(macOS)
                    HStack(spacing: 6) {
                        Label(account.userID, systemImage: "person.crop.circle")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let error = model.collectiveListingErrors[account.id] {
                            Image(systemName: "exclamationmark.icloud")
                                .help("Could not refresh collectives: \(error)")
                                .accessibilityLabel("Could not refresh collectives: \(error)")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .help(account.serverURL.absoluteString)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(account.serverURL.absoluteString)
                    .padding(.top, account.id == model.accounts.first?.id ? 0 : 12)
                    #endif
                    NavigationLink(value: SidebarDestination(accountID: account.id, collectiveID: nil)) {
                        HStack(spacing: 9) {
                            Image(systemName: "house").foregroundStyle(.secondary).frame(width: 20)
                            Text("Home").lineLimit(1)
                        }
                    }
                    ForEach(model.collectives(for: account.id)) { collective in
                        NavigationLink(value: SidebarDestination(accountID: account.id, collectiveID: collective.id)) {
                            HStack(spacing: 9) {
                                if let emoji = collective.emoji, !emoji.isEmpty {
                                    Text(emoji).frame(width: 20)
                                } else {
                                    Image(systemName: "books.vertical").foregroundStyle(.secondary).frame(width: 20)
                                }
                                Text(collective.name).lineLimit(1)
                            }
                        }
                    }
                    if model.collectives(for: account.id).isEmpty {
                        Text(model.collectiveListingErrors[account.id] == nil ? "No collectives" : "No cached collectives")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if account.id == model.activeID && !drafts.isEmpty {
                        Label("Drafts", systemImage: "pencil.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 12)
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
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open Draft", systemImage: "doc.text") {
                                    Task { await model.openDraft(doc.page.id); compactColumn = .detail }
                                }
                                favoriteButton(doc.page.id)
                            }
                        }
                    }
                } header: {
                    #if !os(macOS)
                    Label(account.userID, systemImage: "person.crop.circle")
                        .textCase(nil)
                        .accessibilityValue(account.serverURL.absoluteString)
                    if let error = model.collectiveListingErrors[account.id] {
                        Label("Could not refresh collectives", systemImage: "exclamationmark.icloud")
                            .textCase(nil)
                        Text(error).textCase(nil).font(.caption).foregroundStyle(.secondary)
                    }
                    #endif
                }
            }
            Section {
                Button { model.beginLogin() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "person.badge.plus").frame(width: 20)
                        Text("Add Account…").lineLimit(1)
                    }
                    #if os(macOS)
                    .foregroundStyle(.secondary)
                    #else
                    .foregroundStyle(.tint)
                    #endif
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.busy)
                #if os(macOS)
                .padding(.top, 12)
                #endif
            }
        }
        .font(.body)
        #if os(macOS)
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        #else
        .listStyle(.insetGrouped)
        .refreshable { await model.syncAccounts() }
        #endif
    }
    private var sidebarFooter: some View {
        HStack(spacing: 12) {
            Button { showSyncIssue.toggle() } label: {
                Image(systemName: model.syncSymbol)
                    .symbolEffect(.pulse, isActive: model.syncing)
                    .foregroundStyle(syncNeedsAttention ? Color.orange : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .help("\(model.syncSummary()). Show sync details")
            .accessibilityLabel("Sync status: \(model.syncSummary())")
            .accessibilityHint("Show sync details")
            .disabled(model.activeID == nil && model.syncActivity == nil)
            .popover(isPresented: $showSyncIssue, arrowEdge: .bottom) {
                SyncStatusView(model: model).frame(width: 320)
            }
            .onChange(of: model.activeID) { _, _ in showSyncIssue = false }
            .onDisappear { showSyncIssue = false }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Menu {
                    if model.syncing {
                        Button("Cancel Sync", systemImage: "xmark.circle") { model.cancelSync() }
                            .disabled(!model.canCancelSync)
                    } else {
                        Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.syncAccounts() } }
                            .disabled(model.busy || model.pageMode == .richText)
                    }
                    Divider()
                    Toggle("Automatically Sync Active Account", isOn: $automaticSync)
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Sync Actions")
                #if os(macOS)
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Settings")
                    .accessibilityLabel("Settings")
                #else
                Button { showSettings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Settings")
                #endif
            }.fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
    private var syncNeedsAttention: Bool {
        model.draftSaveFailed || model.conflictCount > 0
            || model.activeID.map { model.syncIssues[$0] != nil } == true
    }

}

@MainActor @Observable
final class LoginSession {
    var isActive = true
    private(set) var working = false
    private(set) var status = "Approve access in your browser. Your account password stays there."
    private let client: LoginFlowClient
    private let delay: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private var server: URL?
    private var flow: LoginFlow?
    private var credentials: LoginCredentials?
    private var deadline: Date?

    init(client: LoginFlowClient = LoginFlowClient(),
         delay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.delay = delay; self.now = now
    }
    var buttonTitle: String {
        if credentials != nil { return "Retry Sign-In" }
        return flow == nil ? "Sign In with Browser" : "Continue Sign-In"
    }
    func signIn(serverURL: URL?, openBrowser: @MainActor (URL) -> Void,
                finish: @MainActor (LoginCredentials) async throws -> Void) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            guard let serverURL else { throw CollectivesError.invalidServer }
            let normalized = try ServerAddress.normalize(serverURL)
            if server != normalized {
                flow = nil; credentials = nil; deadline = nil
                server = normalized
            }
            if flow == nil || credentials != nil { deadline = now().addingTimeInterval(20 * 60) }
            while true {
                try Task.checkCancellation()
                if let deadline, now() >= deadline {
                    if credentials == nil {
                        flow = nil; self.deadline = nil
                        status = "Login expired. Try again."
                    } else {
                        status = "Could not finish sign-in. Retry when you have a connection."
                    }
                    return
                }
                guard isActive else {
                    status = "Return to Collectives after approving access in your browser."
                    try await delay()
                    continue
                }
                do {
                    if let credentials {
                        status = "Completing sign-in…"
                        try await finish(credentials)
                        self.credentials = nil; flow = nil; deadline = nil
                        return
                    }
                    if let flow {
                        if let login = try await client.poll(flow, serverURL: normalized) {
                            try Task.checkCancellation()
                            credentials = login
                            deadline = now().addingTimeInterval(20 * 60)
                            continue
                        }
                        status = "Waiting for browser approval…"
                    } else {
                        let created = try await client.begin(serverURL: normalized)
                        try Task.checkCancellation()
                        flow = created
                        status = "Waiting for browser approval…"
                        openBrowser(created.login)
                    }
                    // Let the browser transition update scene state before starting another request.
                    try await delay()
                } catch {
                    try Task.checkCancellation()
                    guard Self.isTemporaryConnectionError(error) else { throw error }
                    status = "Connection interrupted. Retrying sign-in…"
                    try await delay()
                }
            }
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
        }
    }
    private static func isTemporaryConnectionError(_ error: any Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: error.code) {
        case .networkConnectionLost, .timedOut, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .cancelled:
            return true
        default: return false
        }
    }
}

struct LoginView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var server = "https://"
    @State private var session = LoginSession()
    @State private var loginTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Nextcloud").font(.title2)
            TextField("Server URL", text: $server).textFieldStyle(.roundedBorder).disabled(session.working)
                .onSubmit { begin() }
                #if !os(macOS)
                .keyboardType(.URL).textContentType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            Text(session.status).font(.callout).textSelection(.enabled)
            HStack {
                Button("Cancel") { loginTask?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                ProgressView().controlSize(.small)
                    .opacity(session.working ? 1 : 0)
                    .accessibilityHidden(!session.working)
                Button(session.buttonTitle) { begin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.working)
            }
        }.padding(24).frame(minWidth: 300, idealWidth: 440)
        .onAppear { server = model.loginServer }
        .onChange(of: scenePhase, initial: true) { _, phase in session.isActive = phase == .active }
        .onDisappear { loginTask?.cancel() }
    }
    private func begin() {
        guard !session.working else { return }
        loginTask = Task { @MainActor in
            await session.signIn(serverURL: URL(string: server), openBrowser: { openURL($0) }) { login in
                try await model.addAccount(login)
                dismiss()
            }
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
