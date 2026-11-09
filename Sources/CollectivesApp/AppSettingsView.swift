import SwiftUI
import CollectivesCore

struct AppSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultPageMode") private var defaultPageMode = "preview"
    @AppStorage("rememberPageMode") private var rememberPageMode = false
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
                    ForEach(PageViewMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Toggle("Remember last used page mode", isOn: $rememberPageMode)
                #if os(macOS)
                    .toggleStyle(.checkbox)
                #endif
                Toggle("Close sidebar after switching collective", isOn: $closeSidebarAfterCollectiveSwitch)
            } header: {
                Text("Pages")
            } footer: {
                Text("Pages open in the default mode, or your last used mode when remembering is on; read-only pages always open in View.")
            }
            if !model.accounts.isEmpty {
                Section {
                    ForEach(model.accounts) { account in
                        launchPagePicker(account)
                    }
                } header: {
                    Text("Open at Launch")
                } footer: {
                    Text("Choose a specific page from its actions menu.")
                }
            }
            Section {
                Toggle("Automatically Sync Active Account", isOn: $automaticSync)
            } header: {
                Text("Sync")
            } footer: {
                Text("Keeps pages current while the app is open and syncs drafts when you pause typing.")
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
                                .disabled(model.syncing)
                            Button("Export Backup…") { export(account) }
                            Spacer()
                            Button("Remove…", role: .destructive) { accountToRemove = account }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }.padding(.vertical, 5)
                }
                Button("Add Account…", systemImage: "person.badge.plus") { login(server: nil) }
                    .disabled(model.syncing)
            } header: {
                Text("Accounts")
            } footer: {
                Text("Removing an account deletes its offline pages from this device, so sync its drafts and resolve conflicts first.")
            }
            .disabled(model.busy || working)
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
            Text("Remove \(account.userID) at \(account.serverURL.host ?? account.serverURL.absoluteString) from this device? Its downloaded pages and credentials will be deleted. Pages on Nextcloud are kept. Any sync for this account will stop. Unsynced drafts and conflicts block removal.")
        }
        .alert("Account Action Failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func launchPagePicker(_ account: Account) -> some View {
        let selection = Binding(get: { model.launchPage(accountID: account.id) },
                                set: { model.setLaunchPage($0, accountID: account.id) })
        let label = model.accounts.count == 1 ? "Open at launch" : "\(account.userID) on \(account.serverURL.host ?? account.serverURL.absoluteString)"
        return Picker(label, selection: selection) {
            Text("Last Opened").tag(LaunchPage?.none)
            Text("Home").tag(LaunchPage?.some(.home))
            if case .page(let pageID) = selection.wrappedValue {
                Text(model.pageTitle(pageID, accountID: account.id) ?? "Chosen Page").tag(LaunchPage?.some(.page(pageID)))
            }
        }
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
