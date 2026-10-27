import SwiftUI
import CollectivesCore

#if os(macOS)
private struct CommandPaletteKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var commandPalette: Binding<Bool>? {
        get { self[CommandPaletteKey.self] }
        set { self[CommandPaletteKey.self] = newValue }
    }
}

struct PageNavigationCommands: Commands {
    @FocusedBinding(\.commandPalette) private var isPresented

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Command Palette…") { isPresented = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(isPresented == nil)
        }
    }
}
#endif

struct CommandPaletteView: View {
    @Bindable var model: AppModel
    let accountID: UUID
    let onOpened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: Int?
    @State private var opening = false
    @FocusState private var searchFocused: Bool

    private var results: [PageQuickSearchResult] {
        guard model.activeID == accountID else { return [] }
        return PageQuickSearch.results(in: model.snapshot, query: query, recentPageIDs: model.library.recentPageIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search synced pages…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { openSelection() }
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                    .accessibilityLabel("Search pages across all collectives")
                Button("Close", systemImage: "xmark.circle.fill") { dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            if results.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "No Synced Pages" : "No Matching Pages", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(query.isEmpty ? "Open a collective to sync its page list." : "Try another page title, collective, or parent page.")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results) { result in
                                resultRow(result).id(result.id)
                            }
                        }.padding(8)
                    }
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack {
                Text("↑↓ Select · Return Open · Esc Close")
                Spacer()
                Text("\(results.count) pages")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(idealWidth: 560, idealHeight: 440)
        #if os(macOS)
        .frame(width: 560, height: 440)
        #endif
        .disabled(opening)
        .interactiveDismissDisabled(opening)
        .onAppear { selectedID = results.first?.id; searchFocused = true }
        .onChange(of: query) { _, _ in selectedID = results.first?.id }
        .onChange(of: results.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? -1) { selectedID = ids.first }
        }
        .onChange(of: model.activeID) { _, id in if id != accountID { dismiss() } }
    }

    private func resultRow(_ result: PageQuickSearchResult) -> some View {
        Button { selectedID = result.id; openSelection() } label: {
            HStack(spacing: 10) {
                Group {
                    if let emoji = result.page.emoji, !emoji.isEmpty { Text(emoji) }
                    else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                }.frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.page.title).lineLimit(1)
                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.snapshot.documents[String(result.id)] != nil {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                        .accessibilityLabel("Available offline")
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == result.id ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedID == result.id ? .isSelected : [])
        .disabled(model.busy)
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { selectedID = nil; return }
        let current = results.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results[min(max(current + offset, 0), results.count - 1)].id
    }

    private func openSelection() {
        guard !opening, !model.busy, let result = results.first(where: { $0.id == selectedID }) else { return }
        opening = true
        Task {
            if await model.openQuickSearchResult(result, accountID: accountID) {
                onOpened(); dismiss()
            }
            opening = false
        }
    }
}
