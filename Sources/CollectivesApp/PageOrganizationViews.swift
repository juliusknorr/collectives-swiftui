import SwiftUI
import CollectivesCore

struct PageOrganizationRequest: Identifiable {
    enum Action { case move(Page), trash(Page), restore }
    let id = UUID()
    let accountID: UUID
    let collectiveID: Int
    let action: Action
}

struct PageOrganizationSheet: View {
    @Bindable var model: AppModel
    let request: PageOrganizationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var parentID = 0
    @State private var submitting = false
    @State private var error: String?
    @State private var unconfirmed = false
    @State private var trashedPages: [Page] = []
    @State private var loaded = false

    private var pages: [Page] { model.snapshot.pages[String(request.collectiveID)] ?? [] }
    private var destinations: [Page] {
        guard case .move(let original) = request.action else { return [] }
        return pages.filter { candidate in
            !PageTree.path(to: candidate.id, pages: pages).contains { $0.id == original.id }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var title: String {
        switch request.action {
        case .move: "Move Page"
        case .trash: "Move to Trash?"
        case .restore: "Deleted Pages"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            switch request.action {
            case .move(let page):
                Text(page.title).foregroundStyle(.secondary)
                Picker("New parent", selection: $parentID) {
                    ForEach(destinations) { destination in
                        Text(PageTree.path(to: destination.id, pages: pages).map(\.title).joined(separator: " › "))
                            .tag(destination.id)
                    }
                }.disabled(submitting || unconfirmed)
                Text("The page and its subpages move together. Local drafts and their saved revisions are preserved.")
                    .font(.callout).foregroundStyle(.secondary)
            case .trash(let page):
                Text("Move “\(page.title)” and its subpages to the server trash? Pages with local drafts or conflicts must be synced or resolved first.")
                    .font(.callout)
            case .restore:
                if !loaded { ProgressView("Loading deleted pages…") }
                else if trashedPages.isEmpty { Text("No deleted pages.").foregroundStyle(.secondary) }
                else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(trashedPages) { page in
                                HStack {
                                    Text(page.title).frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Restore") { perform { try await model.restorePage(pageID: page.id, request: request) } }
                                        .disabled(submitting || unconfirmed || model.busy || model.syncing)
                                }
                            }
                        }
                    }.frame(maxHeight: 300)
                }
            }
            Text("Requires a connection.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                switch request.action {
                case .move(let page):
                    Button("Move") { perform { try await model.movePage(pageID: page.id, parentID: parentID, request: request) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(submitting || unconfirmed || model.busy || model.syncing || parentID == page.parentId || !destinations.contains { $0.id == parentID })
                case .trash(let page):
                    Button("Move to Trash", role: .destructive) { perform { try await model.trashPage(pageID: page.id, request: request) } }
                        .disabled(submitting || unconfirmed || model.busy || model.syncing)
                case .restore:
                    if error != nil && !unconfirmed { Button("Retry") { Task { await loadTrash() } }.disabled(submitting) }
                }
            }
        }
        .padding(24).frame(idealWidth: 460)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .interactiveDismissDisabled(submitting)
        .task {
            if case .move(let page) = request.action { parentID = page.parentId }
            if case .restore = request.action { await loadTrash() }
        }
    }
    private func loadTrash() async {
        submitting = true; error = nil
        defer { submitting = false; loaded = true }
        do { trashedPages = try await model.deletedPages(request: request) }
        catch { self.error = error.localizedDescription }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !submitting else { return }
        submitting = true; error = nil
        Task {
            defer { submitting = false }
            do { try await operation(); dismiss() }
            catch {
                self.error = error.localizedDescription
                // A failed write must be reviewed against refreshed server state before retry.
                unconfirmed = true
            }
        }
    }
}

private enum PageOrganizationUIError: LocalizedError {
    case unavailable, unsaved, anotherEditor
    var errorDescription: String? {
        switch self {
        case .unavailable: "Refresh the collective and check your permissions before organizing pages."
        case .unsaved: "Save the current draft on this device before organizing pages."
        case .anotherEditor: "Switch the other windows in this collective to View before organizing pages."
        }
    }
}

extension AppModel {
    private func checkOrganizationRequest(_ request: PageOrganizationRequest) throws {
        guard activeID == request.accountID, selectedCollective == request.collectiveID, canEdit else {
            throw PageOrganizationUIError.unavailable
        }
        guard !session.windows.compactMap(\.value).contains(where: {
            $0.windowID != windowID && $0.activeID == request.accountID
                && $0.selectedCollective == request.collectiveID && $0.pageMode != .view
        }) else { throw PageOrganizationUIError.anotherEditor }
    }

    private func organizePages(
        request: PageOrganizationRequest, success: String,
        operation: (AccountSnapshot, CollectivesClient) async throws -> (AccountSnapshot, [String])
    ) async throws {
        guard !busy, !syncing else { throw PageOrganizationUIError.unavailable }
        try checkOrganizationRequest(request)
        busy = true
        defer { busy = false; resumeTextEditing() }
        await finishTextEditing()
        guard !session.hasRichTextEditor else { throw PageOrganizationUIError.anotherEditor }
        await pendingPersistence?.value
        guard !persistenceFailed else { throw PageOrganizationUIError.unsaved }
        try checkOrganizationRequest(request)
        let api = try await activeClient()
        let (updated, warnings) = try await operation(snapshot, api)
        snapshot = updated
        reconcileSelection()
        do {
            try await persist()
            message = ([success] + warnings).joined(separator: " ")
        } catch {
            message = success + " Local changes could not be saved. Refresh pages when storage is available. " + error.localizedDescription
        }
    }
}

extension AppModel {
    func movePage(pageID: Int, parentID: Int, request: PageOrganizationRequest) async throws {
        try await organizePages(request: request, success: "Page moved on the server.") { snapshot, api in
            let result = try await PageOrganizer.move(pageID: pageID, parentID: parentID,
                collectiveID: request.collectiveID, snapshot: snapshot, api: api)
            return (result.snapshot, result.warnings)
        }
    }
    func trashPage(pageID: Int, request: PageOrganizationRequest) async throws {
        try await organizePages(request: request, success: "Page moved to the server trash.") { snapshot, api in
            let result = try await PageOrganizer.trash(pageID: pageID, collectiveID: request.collectiveID,
                snapshot: snapshot, api: api)
            return (result.snapshot, result.warnings)
        }
    }
    func restorePage(pageID: Int, request: PageOrganizationRequest) async throws {
        try await organizePages(request: request, success: "Page restored on the server.") { snapshot, api in
            let result = try await PageOrganizer.restore(pageID: pageID, collectiveID: request.collectiveID,
                snapshot: snapshot, api: api)
            return (result.snapshot, result.warnings)
        }
    }
    func deletedPages(request: PageOrganizationRequest) async throws -> [Page] {
        guard !busy, !syncing else { throw PageOrganizationUIError.unavailable }
        try checkOrganizationRequest(request)
        let api = try await activeClient()
        let result = try await api.trashedPages(collectiveID: request.collectiveID)
        try checkOrganizationRequest(request)
        return result
    }
}
