import SwiftUI
import CollectivesCore

struct ConflictReviewRequest: Identifiable {
    let id = UUID()
    let accountID: UUID
    let page: Page
    let draft: String?
    let localSource: String
    let remote: RemoteDocument

    @MainActor init?(model: AppModel) {
        guard let accountID = model.activeID, let page = model.selectedPage,
              let document = model.document, let remote = document.conflict else { return nil }
        self.accountID = accountID
        self.page = page
        draft = document.draft
        localSource = model.text
        self.remote = remote
    }
}

struct ConflictReviewSheet: View {
    @Bindable var model: AppModel
    let review: ConflictReviewRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmingServer = false
    @State private var resolving = false
    @State private var resolutionMessage: String?

    private var isCurrent: Bool {
        model.activeID == review.accountID && model.selectedPage == review.page &&
        model.document?.draft == review.draft && model.document?.conflict == review.remote &&
        model.text == review.localSource
    }

    private var canResolve: Bool { isCurrent && !model.busy && !model.syncing && !resolving }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(review.page.title).font(.headline)
                Text("This page changed on the server while you had local changes. Compare both versions before choosing which to keep.")
                    .font(.callout).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    if geometry.size.width >= 680 && !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 16) {
                            sourcePanel("My Changes", source: review.localSource)
                            sourcePanel("Server Changes", source: review.remote.markdown)
                        }
                    } else {
                        VStack(spacing: 16) {
                            sourcePanel("My Changes", source: review.localSource)
                            sourcePanel("Server Changes", source: review.remote.markdown)
                        }
                    }
                }
                if !isCurrent {
                    Label("This page or its changes have changed since you opened the comparison. Close it and review the latest versions before choosing.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
                if let resolutionMessage {
                    Text(resolutionMessage).font(.callout).foregroundStyle(.secondary)
                }
                Text("Keeping your changes saves them as a local draft for the next sync. Using server changes discards your local draft.")
                    .font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        keepLocalButton
                        Spacer()
                        useServerButton
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        keepLocalButton
                        useServerButton
                    }
                }
                .disabled(!canResolve)
                if resolving { ProgressView("Saving your choice…") }
            }
            .padding()
            .navigationTitle("Review Conflict")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(resolving)
                }
            }
            .confirmationDialog("Discard your local changes?", isPresented: $confirmingServer, titleVisibility: .visible) {
                Button("Use Server Changes", role: .destructive) { resolve(useServer: true) }
                    .disabled(!canResolve)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your local draft of “\(review.page.title)” will be replaced by the server version shown here.")
            }
            .interactiveDismissDisabled(resolving)
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 960, minHeight: 540, idealHeight: 700)
        #endif
    }

    private var keepLocalButton: some View {
        Button("Keep My Changes") { resolve(useServer: false) }
            .buttonStyle(.borderedProminent)
    }

    private var useServerButton: some View {
        Button("Use Server Changes", role: .destructive) { confirmingServer = true }
            .buttonStyle(.bordered)
    }

    private func sourcePanel(_ title: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                Text(source.isEmpty ? "This version is empty." : source)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func resolve(useServer: Bool) {
        guard canResolve else { return }
        resolving = true
        resolutionMessage = nil
        Task { @MainActor in
            defer { resolving = false }
            guard isCurrent, !model.busy else { return }
            await model.resolveConflict(useServer: useServer)
            if model.activeID == review.accountID, model.selectedPage == review.page,
               model.document?.conflict == nil {
                dismiss()
            } else {
                resolutionMessage = model.message
            }
        }
    }
}
