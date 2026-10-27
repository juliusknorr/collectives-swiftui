import SwiftUI
import CollectivesCore

struct SyncIssue {
    let message: String
    let requiresSignIn: Bool

    init(message: String, requiresSignIn: Bool = false) {
        self.message = message
        self.requiresSignIn = requiresSignIn
    }

    init(error: any Error) {
        message = error.localizedDescription
        if case CollectivesError.http(401) = error { requiresSignIn = true }
        else { requiresSignIn = false }
    }
}

struct SyncStatusView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let id = model.activeID, let issue = model.syncIssues[id] {
            VStack(alignment: .leading, spacing: 8) {
                Label(issue.requiresSignIn ? "Sign in again to sync" : "Couldn’t sync with Nextcloud",
                      systemImage: issue.requiresSignIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.icloud")
                    .font(.callout.weight(.semibold))
                Text(issue.requiresSignIn
                     ? "Your downloaded pages and local changes are still on this device. Sign in again to reconnect this account."
                     : "Your downloaded pages and local changes are still on this device. Try syncing again. If it still fails, review the details below.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Details") {
                    Text(issue.message).font(.caption).textSelection(.enabled)
                }
                HStack {
                    Button(issue.requiresSignIn ? "Sign In Again…" : "Retry Sync") {
                        if issue.requiresSignIn { model.beginLogin(server: model.account?.serverURL) }
                        else { Task { await model.syncAccounts() } }
                    }
                    .disabled(model.busy || model.syncing)
                    if model.syncing { ProgressView().controlSize(.small); Text("Syncing…").font(.caption) }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        }
    }
}
