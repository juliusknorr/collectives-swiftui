import Foundation
import SwiftUI
import CollectivesCore

@MainActor
struct ClientPreparation {
    let id = UUID()
    let task: Task<CollectivesClient, Error>
}

@MainActor
final class WeakAppWindow {
    weak var value: AppModel?
    init(_ value: AppModel) { self.value = value }
}

@MainActor @Observable
final class AppSession {
    struct DocumentKey: Hashable {
        let accountID: UUID
        let pageID: Int
    }
    var accountsLoaded = false
    var snapshots: [UUID: AccountSnapshot] = [:]
    var libraries: [UUID: PageLibraryState] = [:]
    var windows: [WeakAppWindow] = []
    var editorOwners: [DocumentKey: UUID] = [:]
    var accounts: [Account] = []
    var accountCollectives: [UUID: [Collective]] = [:]
    var collectiveListingErrors: [UUID: String] = [:]
    var busy: Bool = false {
        didSet {
            guard !busy else { return }
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0.resume() }
        }
    }
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilIdle() async {
        while busy { await withCheckedContinuation { idleWaiters.append($0) } }
    }
    var syncing: Bool = false
    var isCancellingSync: Bool = false
    var automaticSyncPaused: Bool = false
    var syncActivity: SyncActivity?
    var syncIssues: [UUID: SyncIssue] = [:]
    var cachedClients: [Account: CollectivesClient] = [:]
    var preparingClients: [Account: ClientPreparation] = [:]
    var clientGeneration: UUID = UUID()
    var accountSyncTasks: [UUID: Task<Void, Error>] = [:]
    var removingAccountIDs: Set<UUID> = []
    var pendingPersistence: Task<Void, Never>?
    var persistenceFailed: Bool = false
    var savingDraft: Bool = false
    var editGeneration: UUID = UUID()
    var syncBaselines: [UUID: AccountSnapshot] = [:]
    var checkpointSnapshots: [UUID: AccountSnapshot] = [:]
    var checkpointVersions: [UUID: Int] = [:]
    var lastEdit: Date = Date.distantPast
    var lastSyncDates: [UUID: Date] = [:]
    func editorOwner(accountID: UUID, pageID: Int) -> UUID? {
        let key = DocumentKey(accountID: accountID, pageID: pageID)
        guard let owner = editorOwners[key] else { return nil }
        guard windows.contains(where: { $0.value?.windowID == owner && $0.value?.activeID == accountID && $0.value?.selectedPage?.id == pageID }) else {
            return nil
        }
        return owner
    }
    var hasRichTextEditor: Bool {
        windows.contains { $0.value?.textSession != nil }
    }
    func refreshWindows(accountID: UUID, except source: UUID? = nil) {
        windows.removeAll { $0.value == nil }
        for window in windows.compactMap(\.value) where window.windowID != source && window.activeID == accountID {
            window.refreshSharedSelection()
        }
    }
}

#if os(macOS)
private struct CollectivesWindowKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var collectivesWindow: AppModel? {
        get { self[CollectivesWindowKey.self] }
        set { self[CollectivesWindowKey.self] = newValue }
    }
}

/// Window actions that open sheets or alerts owned by the window's view; nil disables the menu item.
struct PageCommandActions {
    var newPage: (() -> Void)?
    var rename: (() -> Void)?
    var move: (() -> Void)?
    var trash: (() -> Void)?
    var restoreSource: (() -> Void)?
    var refreshPages: (() -> Void)?
}

private struct PageCommandActionsKey: FocusedValueKey {
    typealias Value = PageCommandActions
}

extension FocusedValues {
    var pageCommandActions: PageCommandActions? {
        get { self[PageCommandActionsKey.self] }
        set { self[PageCommandActionsKey.self] = newValue }
    }
}

struct PageCommands: Commands {
    @FocusedValue(\.collectivesWindow) private var model
    @FocusedValue(\.pageCommandActions) private var actions
    private var isFavorite: Bool {
        model?.selectedPage.map { model?.library.favoritePageIDs.contains($0.id) == true } == true
    }
    private let modeShortcuts: [PageViewMode: KeyEquivalent] = [.view: "1", .edit: "2", .richText: "3"]
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Page…") { actions?.newPage?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.newPage == nil)
        }
        CommandMenu("Page") {
            Button("Rename…") { actions?.rename?() }.disabled(actions?.rename == nil)
            Button("Move…") { actions?.move?() }.disabled(actions?.move == nil)
            Button("Move to Trash…") { actions?.trash?() }.disabled(actions?.trash == nil)
            Divider()
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                if let id = model?.selectedPage?.id { model?.toggleFavorite(id) }
            }
            .keyboardShortcut("d")
            .disabled(model?.selectedPage == nil)
            Divider()
            ForEach(PageViewMode.allCases, id: \.self) { mode in
                Toggle(mode.title, isOn: Binding(get: { model?.pageMode == mode }, set: { _ in
                    Task { await model?.changePageMode(mode) }
                }))
                .keyboardShortcut(modeShortcuts[mode]!)
                .disabled(model?.document == nil || model?.busy == true || model?.canEdit != true)
            }
            Divider()
            Button("Refresh Pages") { actions?.refreshPages?() }
                .keyboardShortcut("r")
                .disabled(actions?.refreshPages == nil)
            if actions?.restoreSource != nil {
                Divider()
                Button("Restore Source from Before Text Editing…") { actions?.restoreSource?() }
            }
        }
    }
}

struct WindowSyncCommands: Commands {
    @FocusedValue(\.collectivesWindow) private var model
    @AppStorage("automaticSync") private var automaticSync = true
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Sync Page Changes") { Task { await model?.syncLocalChanges() } }
                .keyboardShortcut("s")
                .disabled(model == nil)
            Button("Sync All Accounts") { Task { await model?.syncAccounts() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model == nil || model?.busy == true || model?.syncing == true || model?.session.hasRichTextEditor == true)
            Toggle("Automatically Sync Active Account", isOn: $automaticSync)
        }
    }
}

#endif
