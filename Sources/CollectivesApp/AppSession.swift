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
    var busy: Bool = false
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

struct WindowSyncCommands: Commands {
    @FocusedValue(\.collectivesWindow) private var model
    @AppStorage("automaticSync") private var automaticSync = true
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Sync Current Page") { Task { await model?.sync() } }
                .keyboardShortcut("s")
                .disabled(model == nil || model?.busy == true || model?.syncing == true || model?.session.hasRichTextEditor == true || model?.selectedPage == nil)
            Button("Sync All Accounts") { Task { await model?.syncAccounts() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model == nil || model?.busy == true || model?.syncing == true || model?.session.hasRichTextEditor == true)
            Toggle("Automatically Sync Active Account", isOn: $automaticSync)
        }
    }
}

#endif
