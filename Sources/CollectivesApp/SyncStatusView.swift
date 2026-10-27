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

struct SyncActivity {
    let account: Account
    let accountIndex: Int
    let accountTotal: Int
    let progress: AccountSyncProgress

    var title: String {
        switch progress.phase {
        case .listingCollectives: "Loading collectives…"
        case .listingPages: "Loading pages…"
        case .downloading: "Downloading page…"
        case .uploading: "Uploading draft…"
        case .checking: "Checking page…"
        case .saving: "Saving locally…"
        case .finished: "Sync finished"
        }
    }
    var pageCount: String? {
        progress.totalPages.map { "\(progress.completedPages) of \($0) pages processed" }
    }
    var summary: String {
        pageCount ?? title
    }
}

struct SyncProgressView: View {
    let activity: SyncActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(activity.title).font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if let count = activity.pageCount { Text(count).font(.caption).monospacedDigit() }
            }
            if let total = activity.progress.totalPages, total > 0 {
                ProgressView(value: Double(activity.progress.completedPages), total: Double(total))
            } else { ProgressView().controlSize(.small) }
            Text("\(activity.account.userID) · \(activity.account.serverURL.host() ?? activity.account.serverURL.absoluteString)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let collective = activity.progress.collective {
                Text([collective.name, activity.progress.page?.title].compactMap { $0 }.joined(separator: " › "))
                    .font(.caption).lineLimit(2)
            }
            HStack {
                if activity.accountTotal > 1 {
                    Text("Account \(activity.accountIndex) of \(activity.accountTotal)")
                }
                if let total = activity.progress.totalCollectives, total > 1 {
                    Text("Collective \(min(activity.progress.completedCollectives + 1, total)) of \(total)")
                }
                if activity.progress.failureCount > 0 {
                    Text("\(activity.progress.failureCount) failed").foregroundStyle(.orange)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SyncStatusView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let activity = model.syncActivity { SyncProgressView(activity: activity) }
            else if model.activeID.map({ model.syncIssues[$0] == nil }) == true {
                Label(model.syncSummary, systemImage: model.syncSymbol).font(.callout)
            }
            if let id = model.activeID, let issue = model.syncIssues[id] {
                VStack(alignment: .leading, spacing: 8) {
                    Label(issue.requiresSignIn ? "Sign in again to sync" : "Couldn’t sync with Nextcloud",
                          systemImage: issue.requiresSignIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.icloud")
                        .font(.callout.weight(.semibold))
                    Text(issue.requiresSignIn
                         ? "Your downloaded pages and local changes are still on this device. Sign in again to reconnect this account."
                         : "Your downloaded pages and local changes are still on this device. Try syncing again. If it still fails, review the details below.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(issue.message).font(.caption).textSelection(.enabled)
                    HStack {
                        Button(issue.requiresSignIn ? "Sign In Again…" : "Retry Sync") {
                            if issue.requiresSignIn {
                                dismiss()
                                model.beginLogin(server: model.account?.serverURL)
                            }
                            else { Task { await model.syncAccounts() } }
                        }
                        .disabled(model.busy || model.syncing)
                        if model.syncing { ProgressView().controlSize(.small); Text("Syncing…").font(.caption) }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
}
