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

private struct AutomaticSyncIdentity: Equatable {
    let active: Bool
    let accountID: UUID?
    let collectiveIDs: [Int]
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
                .task(id: AutomaticSyncIdentity(
                    active: scenePhase == .active && automaticSync && model.startupComplete,
                    accountID: model.activeID,
                    collectiveIDs: model.snapshot.collectives.map(\.id)
                )) {
                    guard scenePhase == .active, automaticSync, model.startupComplete else { return }
                    await model.runAutomaticSync()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 750)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            PageNavigationCommands()
            CommandGroup(after: .newItem) {
                Button("Sync Current Page") { Task { await model.sync() } }
                    .keyboardShortcut("s").disabled(model.busy || model.syncing || model.selectedPage == nil)
                Button("Sync All Accounts") { Task { await model.syncAccounts() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.busy || model.syncing)
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
    var accountCollectives: [UUID: [Collective]] = [:]
    var collectiveListingErrors: [UUID: String] = [:]
    var activeID: UUID?
    var snapshot = AccountSnapshot()
    var selectedCollective: Int?
    var selectedPage: Page?
    var text = ""
    var message = ""
    var busy = false
    var syncing = false
    var syncIssues: [UUID: SyncIssue] = [:]
    var showLogin = false
    var settingsLogin = false
    var loginServer = "https://"
    var started = false
    var startupComplete = false
    var library = PageLibraryState()
    private let preferences: LibraryPreferences
    private let store: LocalStore
    private let credentials = KeychainCredentialStore()
    private let makeClient: @MainActor (Account) throws -> CollectivesClient
    private var clients: [UUID: CollectivesClient] = [:]
    private var pushConnected = false
    private var remoteSyncRequested = false
    private var automaticSyncGeneration: UUID?
    private var pendingPersistence: Task<Void, Never>?
    private var persistenceFailed = false
    var savingDraft = false
    var draftSaveFailed: Bool { persistenceFailed }
    private var editGeneration = UUID()
    private var syncBaselines: [UUID: AccountSnapshot] = [:]
    private var checkpointSnapshots: [UUID: AccountSnapshot] = [:]
    private var checkpointVersions: [UUID: Int] = [:]
    private var lastEdit = Date.distantPast

    init(store: LocalStore? = nil, preferences: LibraryPreferences = LibraryPreferences(),
         makeClient: (@MainActor (Account) throws -> CollectivesClient)? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.store = store ?? LocalStore(root: base.appendingPathComponent("Collectives", isDirectory: true))
        self.preferences = preferences
        self.makeClient = makeClient ?? { account in
            guard let credential = try KeychainCredentialStore().credential(accountID: account.id) else {
                throw CollectivesError.invalidResponse
            }
            return CollectivesClient(account: account, credential: credential)
        }
    }
    var account: Account? { accounts.first { $0.id == activeID } }
    var pages: [Page] { snapshot.pages[String(selectedCollective ?? -1)] ?? [] }
    var document: CachedDocument? { selectedPage.flatMap { snapshot.documents[String($0.id)] } }
    var pendingCount: Int { snapshot.documents.values.filter { $0.draft != nil }.count }
    var conflictCount: Int { snapshot.documents.values.filter { $0.conflict != nil }.count }
    var downloadedCount: Int { pages.filter { snapshot.documents[String($0.id)] != nil }.count }
    var canEdit: Bool { snapshot.collectives.first { $0.id == selectedCollective }?.canEdit == true }
    var syncSummary: String {
        if savingDraft { return "Saving locally…" }
        if draftSaveFailed { return "Changes not saved" }
        if syncing { return "Syncing…" }
        if let id = activeID, let issue = syncIssues[id] {
            return issue.requiresSignIn ? "Sign in to sync" : "Sync needs attention"
        }
        if conflictCount > 0 { return "\(conflictCount) \(conflictCount == 1 ? "conflict" : "conflicts") to review" }
        return pendingCount == 0 ? "No pending drafts" : "\(pendingCount) pending \(pendingCount == 1 ? "draft" : "drafts")"
    }
    var syncSymbol: String {
        if draftSaveFailed || conflictCount > 0 { return "exclamationmark.triangle" }
        if let id = activeID, syncIssues[id] != nil { return "exclamationmark.icloud" }
        return pendingCount > 0 ? "pencil.circle" : "checkmark.icloud"
    }

    func start() async {
        guard !started else { return }; started = true
        defer { startupComplete = true }
        do {
            accounts = try await store.accounts()
            for account in accounts {
                do { accountCollectives[account.id] = try await store.snapshot(accountID: account.id).collectives }
                catch { collectiveListingErrors[account.id] = error.localizedDescription }
            }
            if let target = accounts.first(where: { $0.id == preferences.lastAccountID }) ?? accounts.first {
                await selectAccount(target.id)
                await syncAccounts()
                await restoreSelection()
            } else {
                message = "Add an account to get started."
            }
        } catch { message = error.localizedDescription }
    }
    func client() throws -> CollectivesClient {
        guard let account else { throw CollectivesError.invalidResponse }
        return try client(for: account)
    }
    /// One client per account keeps Keychain reads and URL sessions out of the render and sync loops.
    private func client(for account: Account) throws -> CollectivesClient {
        if let cached = clients[account.id] { return cached }
        let created = try makeClient(account)
        clients[account.id] = created
        return created
    }
    func selectAccount(_ id: UUID) async {
        guard !busy, accounts.contains(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft successfully before switching accounts."; return }
        _ = await loadAccount(id)
    }
    private func loadAccount(_ id: UUID) async -> Bool {
        if let previousID = activeID { accountCollectives[previousID] = snapshot.collectives }
        let version = checkpointVersions[id, default: 0]
        let loaded: AccountSnapshot
        do {
            await pendingPersistence?.value
            let stored = try await store.snapshot(accountID: id)
            loaded = checkpointVersions[id, default: 0] == version ? stored : checkpointSnapshots[id] ?? stored
        } catch { message = error.localizedDescription; return false }
        activeID = id; selectedCollective = nil; selectedPage = nil; text = ""
        snapshot = loaded
        accountCollectives[id] = loaded.collectives
        library = preferences.load(accountID: id)
        preferences.lastAccountID = id
        do {
            let remote = try await client().collectives()
            snapshot.replaceCollectives(remote)
            accountCollectives[id] = snapshot.collectives
            try await persist(); message = "Collectives refreshed."
            collectiveListingErrors[id] = nil
        } catch {
            collectiveListingErrors[id] = error.localizedDescription
            syncIssues[id] = SyncIssue(error: error)
            message = "Using cached content."
        }
        return true
    }
    func persist() async throws {
        guard let id = activeID else { return }
        try await store.saveSnapshot(snapshot, accountID: id)
    }
    func collectives(for accountID: UUID) -> [Collective] {
        accountID == activeID ? snapshot.collectives : accountCollectives[accountID] ?? []
    }
    func refresh(excludingActive: Bool = false) async {
        let targets = accounts.filter { !excludingActive || $0.id != activeID }
        guard !busy, !syncing, !targets.isEmpty else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft before refreshing collectives."; return }
        for target in targets {
            do {
                var local = target.id == activeID ? snapshot : try await store.snapshot(accountID: target.id)
                let remote = try await client(for: target).collectives()
                local.replaceCollectives(remote)
                accountCollectives[target.id] = local.collectives
                if target.id == activeID { snapshot = local }
                try await store.saveSnapshot(local, accountID: target.id)
                collectiveListingErrors[target.id] = nil
            } catch { collectiveListingErrors[target.id] = error.localizedDescription }
        }
        if !excludingActive {
            message = collectiveListingErrors.isEmpty ? "Collectives refreshed for all accounts." :
                "Some accounts could not be refreshed. Their cached collectives are shown."
        }
    }
    @discardableResult
    func openCollective(_ id: Int) async -> Bool {
        guard !busy, snapshot.collectives.contains(where: { $0.id == id }) else { return false }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft before switching collectives."; return false }
        await loadCollective(id)
        return true
    }
    func openSidebar(accountID: UUID, collectiveID: Int?) async -> Bool {
        guard !busy, accounts.contains(where: { $0.id == accountID }) else { return false }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft before switching pages."; return false }
        if activeID != accountID {
            guard await loadAccount(accountID) else { return false }
        }
        if let collectiveID {
            guard snapshot.collectives.contains(where: { $0.id == collectiveID }) else { return false }
            await loadCollective(collectiveID)
        } else {
            showHome()
        }
        return true
    }
    private func loadCollective(_ id: Int) async {
        selectedCollective = id; selectedPage = nil; text = ""
        library.collectiveID = id; library.pageID = nil; saveLibrary()
        do {
            snapshot.replacePages(try await client().pages(collectiveID: id), collectiveID: id)
            try await persist(); message = "Select a page."
        } catch {
            if let id = activeID { syncIssues[id] = SyncIssue(error: error) }
            message = "Using cached pages."
        }
    }
    func openPage(_ page: Page) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { message = "Save the current draft before switching pages."; return }
        await loadPage(page)
    }
    private func loadPage(_ page: Page) async {
        selectedPage = page
        if let collectiveID = selectedCollective {
            library.visit(pageID: page.id, collectiveID: collectiveID); saveLibrary()
        }
        let key = String(page.id)
        if let cached = snapshot.documents[key] {
            text = cached.draft ?? cached.markdown
            message = cached.conflict != nil ? "Conflict: local draft preserved. Choose Review Changes to compare versions." :
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
        let saved = doc
        let generation = UUID()
        editGeneration = generation; savingDraft = true
        let previous = pendingPersistence
        message = "Saving draft locally…"
        pendingPersistence = Task {
            await previous?.value
            do {
                try await store.saveDocument(saved, accountID: id)
                persistenceFailed = false
                if editGeneration == generation { savingDraft = false }
                if activeID == id && editGeneration == generation { message = "Draft saved locally; waiting to sync." }
            } catch { savingDraft = false; persistenceFailed = true; message = "Draft not saved: \(error.localizedDescription)" }
        }
    }
    func sync() async {
        guard !busy, !syncing, let page = selectedPage, let target = account else { return }
        syncing = true; defer { syncing = false; syncBaselines = [:] }
        await pendingPersistence?.value
        guard !persistenceFailed, activeID == target.id, selectedPage?.id == page.id,
              let doc = snapshot.documents[String(page.id)] else { return }
        guard doc.conflict == nil else { message = "Review the conflict before syncing."; return }
        let base = snapshot
        do {
            let updated = try await DocumentSynchronizer.synchronize(document: doc, api: client(for: target))
            var next = base
            next.documents[String(page.id)] = updated
            try await applySync(next, startedFrom: base, accountID: target.id)
            syncIssues[target.id] = nil
            if activeID == target.id, selectedPage?.id == page.id {
                message = document?.conflict == nil ? "Synced with server." : "Server changed. Your changes are saved for review."
            }
        } catch { syncIssues[target.id] = SyncIssue(error: error) }
    }
    func downloadCollective() async {
        guard !busy, !syncing, let collectiveID = selectedCollective, let id = activeID else { return }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { return }
        message = "Downloading page text for offline use…"
        let previous = snapshot
        do {
            let localStore = store
            let result = try await AccountSynchronizer.download(collectiveID: collectiveID, snapshot: snapshot, api: client()) { value in
                try await localStore.saveSnapshot(value, accountID: id)
            }
            snapshot = result.snapshot
            reconcileSelection()
            message = result.failures.isEmpty
                ? "Downloaded \(downloadedCount) page bodies. Existing drafts preserved. Images and attachments are not downloaded yet."
                : "Download incomplete; \(result.failures.count) pages need retry. Saved pages remain offline."
        } catch {
            // Keep successful checkpoints if a later step fails.
            snapshot = (try? await store.snapshot(accountID: id)) ?? previous
            reconcileSelection()
            message = "Download incomplete; saved pages remain offline. \(error.localizedDescription)"
        }
    }
    @discardableResult
    func syncAccounts(automatic: Bool = false) async -> Bool {
        guard !busy, !syncing, !showLogin, !settingsLogin else { return false }
        if automatic && Date().timeIntervalSince(lastEdit) < 5 { return false }
        syncing = true; defer { syncing = false; syncBaselines = [:] }
        await pendingPersistence?.value
        guard !persistenceFailed else { return false }
        let targets = automatic ? accounts.filter { $0.id == activeID } : accounts
        for target in targets {
            if Task.isCancelled { return false }
            do {
                let base = target.id == activeID ? snapshot : try await store.snapshot(accountID: target.id)
                let result = try await AccountSynchronizer.synchronize(snapshot: base, api: client(for: target)) { value in
                    try await self.applySync(value, startedFrom: base, accountID: target.id)
                }
                collectiveListingErrors[target.id] = result.failures.first?.message
                if let failure = result.failures.first {
                    syncIssues[target.id] = SyncIssue(message: failure.message,
                        requiresSignIn: result.failures.contains(where: \.requiresSignIn))
                } else { syncIssues[target.id] = nil }
            } catch {
                if Task.isCancelled { return false }
                collectiveListingErrors[target.id] = error.localizedDescription
                syncIssues[target.id] = SyncIssue(error: error)
            }
        }
        return true
    }

    private func applySync(_ remote: AccountSnapshot, startedFrom base: AccountSnapshot, accountID: UUID) async throws {
        // Flush local writes before reading an account that may no longer be active.
        await pendingPersistence?.value
        let current: AccountSnapshot
        if accountID == activeID { current = snapshot }
        else {
            let stored = try await store.snapshot(accountID: accountID)
            current = accountID == activeID ? snapshot : stored
        }
        let merged = current.mergingSync(remote, startedFrom: syncBaselines[accountID] ?? base)
        syncBaselines[accountID] = remote
        checkpointVersions[accountID, default: 0] += 1
        checkpointSnapshots[accountID] = merged
        accountCollectives[accountID] = merged.collectives
        if accountID == activeID {
            snapshot = merged
            reconcileSelection()
        }
        let previous = pendingPersistence
        let save = Task { @MainActor in
            await previous?.value
            try await store.saveSnapshot(merged, accountID: accountID)
        }
        pendingPersistence = Task {
            do { try await save.value }
            catch { persistenceFailed = true; message = "Draft not saved: \(error.localizedDescription)" }
        }
        try await save.value
    }
    private func reconcileSelection() {
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
                if remoteSyncRequested || now.timeIntervalSince(lastRefresh) >= interval {
                    // Clear first so a push arriving during the request schedules another pass.
                    remoteSyncRequested = false
                    if await syncAccounts(automatic: true) { lastRefresh = now; lastDraftSync = now }
                    else { remoteSyncRequested = true }
                } else if now.timeIntervalSince(lastDraftSync) >= 30 {
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
                let api = try client(for: target)
                guard let endpoint = try await api.notifyPushEndpoint(),
                      let credential = try credentials.credential(accountID: target.id) else { return }
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
        guard !busy, !syncing, !showLogin, !settingsLogin else { return }
        if automatic {
            guard Date().timeIntervalSince(lastEdit) >= 5,
                  snapshot.documents.values.contains(where: { $0.draft != nil && $0.conflict == nil }) else { return }
        }
        syncing = true; defer { syncing = false; syncBaselines = [:] }
        await pendingPersistence?.value
        guard !persistenceFailed else { return }
        let targets = automatic ? accounts.filter { $0.id == activeID } : accounts
        for target in targets {
            do {
                let base = target.id == activeID ? snapshot : try await store.snapshot(accountID: target.id)
                var remote = base
                let api = try client(for: target)
                for key in base.documents.keys.sorted() {
                    try Task.checkCancellation()
                    guard let doc = base.documents[key], doc.draft != nil, doc.conflict == nil else { continue }
                    remote.documents[key] = try await DocumentSynchronizer.synchronize(document: doc, api: api)
                    try await applySync(remote, startedFrom: base, accountID: target.id)
                }
                // Draft-only sync cannot establish that a previous account refresh error has recovered.
            } catch {
                if Task.isCancelled { return }
                syncIssues[target.id] = SyncIssue(error: error)
            }
        }
    }
    private func updateEditor() {
        if let doc = document { text = doc.draft ?? doc.markdown }
    }
    func resolveConflict(useServer: Bool) async {
        guard !busy, !syncing, let page = selectedPage, var doc = document, let remote = doc.conflict else { return }
        busy = true; defer { busy = false }
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
        guard !busy, !syncing else { throw CollectivesError.invalidResponse }
        busy = true
        defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { throw CollectivesError.invalidResponse }
        let credentialStore = credentials
        try await store.removeAccount(accountID: id) { try credentialStore.remove(accountID: $0) }
        accounts.removeAll { $0.id == id }
        accountCollectives[id] = nil
        collectiveListingErrors[id] = nil
        clients[id] = nil
        checkpointSnapshots[id] = nil; checkpointVersions[id] = nil
        syncIssues[id] = nil
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
    private func showHome() {
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
    func openQuickSearchResult(_ result: PageQuickSearchResult, accountID: UUID) async -> Bool {
        guard !busy, activeID == accountID else { return false }
        busy = true; defer { busy = false }
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
        guard !busy, !syncing, canEdit, let page = selectedPage, let collectiveID = selectedCollective,
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
        guard !busy, !syncing, activeID == accountID, selectedCollective == collectiveID, canEdit else {
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
    func renamePage(title: String, pageID: Int, collectiveID: Int, accountID: UUID) async throws {
        guard !busy, !syncing, activeID == accountID, selectedCollective == collectiveID, canEdit else {
            throw CollectivesError.invalidResponse
        }
        busy = true; defer { busy = false }
        await pendingPersistence?.value
        guard !persistenceFailed else { throw PageRenamingError.unsavedDraft }
        let result = try await PageRenamer.rename(title: title, pageID: pageID, collectiveID: collectiveID,
            snapshot: snapshot, api: client())
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
        guard !busy, !syncing else { throw CollectivesError.invalidResponse }
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
        clients[new.id] = nil
        syncIssues[new.id] = nil
        if existing == nil { accounts.append(new) }
        try await store.saveAccounts(accounts)
        busy = false
        await selectAccount(new.id)
        await syncAccounts(automatic: true)
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
    @AppStorage("defaultPageMode") private var defaultPageMode = "preview"
    @AppStorage("closeSidebarAfterCollectiveSwitch") private var closeSidebarAfterCollectiveSwitch = false
    @State private var showCommandPalette = false
    @State private var showSettings = false
    @State private var showSyncIssue = false
    @State private var newPageRequest: NewPageRequest?
    @State private var renamePageRequest: RenamePageRequest?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var homeColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var editing = false
    @State private var showingOutline = false
    @State private var showingFind = false
    @State private var conflictReview: ConflictReviewRequest?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    var body: some View {
        Group {
            if model.selectedCollective == nil {
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
                    pageList
                } detail: {
                    detailContent
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Command Palette", systemImage: "magnifyingglass") { showCommandPalette = true }
                    .help("Search all synced pages (⌘K)")
                    .disabled(model.busy || model.account == nil)
                    #if !os(macOS)
                    .keyboardShortcut("k", modifiers: .command)
                    #endif
            }
        }
        #if os(macOS)
        .focusedSceneValue(\.commandPalette, model.account != nil && !model.busy ? $showCommandPalette : nil)
        .toolbarBackground(AppSurface.chrome, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        #endif
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
        .sheet(item: $conflictReview) { review in
            ConflictReviewSheet(model: model, review: review)
        }
        .sheet(isPresented: $model.showLogin) { LoginView(model: model) }
        #if !os(macOS)
        .sheet(isPresented: $showSettings) { AppSettingsView(model: model) }
        #endif
        .onChange(of: pageIdentity, initial: true) { _, _ in editing = defaultPageMode == "edit" }

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
                .disabled(model.busy || model.syncing || !model.canEdit || model.pages.isEmpty)
            Menu {
                Button("New Page…", systemImage: "doc.badge.plus") { beginNewPage() }
                    .disabled(!model.canEdit || model.pages.isEmpty)
                Button("Rename Page…", systemImage: "pencil") {
                    if let page = model.selectedPage { beginRename(page) }
                }.disabled(!model.canEdit || model.selectedPage == nil || model.selectedPage?.parentId == 0)
                Button("Download for Offline Editing", systemImage: "arrow.down.circle") { Task { await model.downloadCollective() } }
                Button("Refresh Pages", systemImage: "arrow.clockwise") {
                    if let id = model.selectedCollective { Task { await model.openCollective(id) } }
                }
            } label: { Label("Collective Actions", systemImage: "ellipsis.circle") }
                .disabled(model.busy || model.syncing || model.selectedCollective == nil)
        }
    }
    private var detailContent: some View {
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
                    .disabled(model.busy || model.syncing)
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
            model.activeID.map { SidebarDestination(accountID: $0, collectiveID: model.selectedCollective) }
        }, set: { destination in
            guard let destination else { return }
            Task {
                let previous = model.activeID.map {
                    SidebarDestination(accountID: $0, collectiveID: model.selectedCollective)
                }
                if await model.openSidebar(accountID: destination.accountID, collectiveID: destination.collectiveID) {
                    search = ""
                    if destination.collectiveID == nil { compactColumn = .detail }
                    else if previous?.collectiveID == nil {
                        columnVisibility = closeSidebarAfterCollectiveSwitch ? .doubleColumn : .all
                        compactColumn = .content
                    } else if previous != destination && closeSidebarAfterCollectiveSwitch {
                        columnVisibility = .doubleColumn
                        compactColumn = .content
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
            Button("Rename…", systemImage: "pencil") { beginRename(page) }
                .disabled(model.busy || model.syncing || !model.canEdit || page.parentId == 0)
            Button("New Subpage…", systemImage: "doc.badge.plus") { beginNewPage(parent: page) }
                .disabled(model.busy || model.syncing || !model.canEdit)
        }
        .help(([collectiveTitle] + pagePath(page).map { $0.title } + [page.title]).joined(separator: " › "))
    }
    private var sidebarList: some View {
        List(selection: collectiveSelection) {
            ForEach(model.accounts) { account in
                Section {
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
                    NavigationLink(value: SidebarDestination(accountID: account.id, collectiveID: nil)) {
                        HStack(spacing: 9) {
                            Image(systemName: "house").foregroundStyle(.secondary).frame(width: 20)
                            Text("Home").lineLimit(1)
                        }
                    }.disabled(model.busy)
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
                        }.disabled(model.busy)
                    }
                    if model.collectives(for: account.id).isEmpty {
                        Text(model.collectiveListingErrors[account.id] == nil ? "No collectives" : "No cached collectives")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if account.id == model.activeID && !drafts.isEmpty {
                        Label("Drafts", systemImage: "pencil.circle")
                            .font(.caption).foregroundStyle(.secondary)
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
            Button { model.beginLogin() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "person.badge.plus").frame(width: 20)
                    Text("Add Account…").lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.busy)
        }
        .font(.body)
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            if let id = model.activeID, model.syncIssues[id] != nil {
                Button { showSyncIssue.toggle() } label: {
                    Label(model.syncSummary, systemImage: model.syncSymbol)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show sync error details")
                .popover(isPresented: $showSyncIssue, arrowEdge: .bottom) {
                    SyncStatusView(model: model).frame(width: 320)
                }
                .onChange(of: model.activeID) { _, _ in showSyncIssue = false }
                .onDisappear { showSyncIssue = false }
            } else {
                if model.busy || model.syncing { ProgressView().controlSize(.small) }
                else { Image(systemName: model.syncSymbol).foregroundStyle(.secondary) }
                Text(model.syncSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Sync All Accounts", systemImage: "arrow.triangle.2.circlepath") { Task { await model.syncAccounts() } }
                Button("Refresh All Collectives", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                Divider()
                Toggle("Auto-sync Active Account", isOn: $automaticSync)
            } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize().disabled(model.busy || model.syncing)
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
