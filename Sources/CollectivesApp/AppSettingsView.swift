import SwiftUI
import CollectivesCore

struct AppSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultPageMode") private var defaultPageMode = "preview"
    @AppStorage("closeSidebarAfterCollectiveSwitch") private var closeSidebarAfterCollectiveSwitch = false
    @AppStorage("automaticSync") private var automaticSync = true
    @State private var accountToRemove: Account?
    @State private var errorMessage: String?
    @State private var backup: String?
    @State private var working = false

    var body: some View {
        #if os(macOS)
        settingsForm
            .frame(width: 560, height: 600)
        #else
        NavigationStack {
            settingsForm
                .navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section {
                Picker("Default page mode", selection: $defaultPageMode) {
                    Text("Preview").tag("preview")
                    Text("Edit Markdown").tag("edit")
                }
                Toggle("Close sidebar after switching collective", isOn: $closeSidebarAfterCollectiveSwitch)
            } header: {
                Text("Pages")
            } footer: {
                Text("The default mode applies when you open a page. Read-only pages always open in Preview. Closing the sidebar keeps the page list available on larger screens.")
            }
            Section {
                Toggle("Automatically sync active account", isOn: $automaticSync)
            } header: {
                Text("Sync")
            } footer: {
                Text("Refreshes pages while the app is active and syncs saved drafts after typing pauses. Uses server push when available. Conflicts stay on this device for review.")
            }
            Section {
                if model.accounts.isEmpty {
                    Text("No accounts connected").foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(account.userID, systemImage: "person.crop.circle")
                                .font(.headline)
                            Spacer()
                            if model.activeID == account.id {
                                Text("Active").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(account.serverURL.absoluteString)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("Sign In Again…") { login(server: account.serverURL) }
                            Button("Export Backup…") { export(account) }
                            Spacer()
                            Button("Remove…", role: .destructive) { accountToRemove = account }
                        }.controlSize(.small)
                    }.padding(.vertical, 5)
                }
                Button("Add Account…", systemImage: "person.badge.plus") { login(server: nil) }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Each account has its own offline pages and drafts. Removing an account clears its credentials and downloads on this device. Accounts with unsynced drafts or conflicts must be synced or resolved first.")
            }
            .disabled(model.busy || model.syncing || working)
            if let backup {
                Section("Source Backup") {
                    ShareLink("Save Account Backup…", item: backup)
                    Text("Includes downloaded Markdown, local drafts and conflict copies. Store it somewhere private. Credentials are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if working { ProgressView() }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $model.settingsLogin) { LoginView(model: model) }
        .confirmationDialog("Remove this account?", isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } }
        ), titleVisibility: .visible, presenting: accountToRemove) { account in
            Button("Remove Account", role: .destructive) { remove(account) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("Remove \(account.userID) at \(account.serverURL.host ?? account.serverURL.absoluteString) from this device? Its downloaded pages and credentials will be deleted. Pages on Nextcloud are kept. Unsynced drafts and conflicts block removal.")
        }
        .alert("Account Action Failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func login(server: URL?) {
        model.loginServer = server?.absoluteString ?? "https://"
        model.settingsLogin = true
    }
    private func export(_ account: Account) {
        working = true
        Task {
            defer { working = false }
            do { backup = try await model.accountBackup(account.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func remove(_ account: Account) {
        working = true
        Task {
            defer { working = false }
            do { try await model.removeAccount(account.id); backup = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
