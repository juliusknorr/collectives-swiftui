import SwiftUI
import CollectivesCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
private final class MarkdownEditorActions: ObservableObject {
    var format: ((MarkdownEditing.Command) -> Void)?
    var find: (() -> Void)?
}

private let formattingTools: [(title: String, icon: String, command: MarkdownEditing.Command)] = [
    ("Heading", "textformat.size", .heading), ("Bold", "bold", .bold), ("Italic", "italic", .italic),
    ("Link", "link", .link), ("Task", "checklist", .task), ("Code", "chevron.left.forwardslash.chevron.right", .code)
]

struct MarkdownSourceEditor: View {
    @Binding var text: String
    var disabled: Bool
    @Binding var showingFind: Bool
    var focusOnAppear = false
    @StateObject private var actions = MarkdownEditorActions()

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(formattingTools.indices, id: \.self) { index in
                        if index == 3 { Divider().frame(height: 18).padding(.horizontal, 4) }
                        tool(formattingTools[index].title, icon: formattingTools[index].icon, command: formattingTools[index].command)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .disabled(disabled)
            Divider()
            #endif
            NativeMarkdownEditor(text: $text, disabled: disabled, focusOnAppear: focusOnAppear, actions: actions)
        }
        .onAppear { showingFind = false }
        .onChange(of: showingFind) { _, shown in
            guard shown else { return }
            actions.find?()
            showingFind = false
        }
    }

    private func tool(_ title: String, icon: String, command: MarkdownEditing.Command) -> some View {
        Button { actions.format?(command) } label: {
            Image(systemName: icon).frame(minWidth: 28, minHeight: 26)
        }
        .accessibilityLabel(title)
        .help(command == .link ? "Insert Link (⌘⇧K)" : title)
    }
}

#if os(macOS)
private struct NativeMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var disabled: Bool
    var focusOnAppear: Bool
    let actions: MarkdownEditorActions

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = SourceTextView()
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.drawsBackground = false
        view.textColor = .textColor
        view.delegate = context.coordinator
        view.string = text
        view.isEditable = !disabled
        view.setAccessibilityLabel("Markdown source")
        scroll.documentView = view
        context.coordinator.view = view
        view.format = { [weak coordinator = context.coordinator] in coordinator?.format($0) }
        actions.format = { [weak coordinator = context.coordinator] in coordinator?.format($0) }
        actions.find = { [weak view] in
            guard let view else { return }
            let showFind = NSMenuItem()
            showFind.tag = NSTextFinder.Action.showFindInterface.rawValue
            view.window?.makeFirstResponder(view)
            view.performTextFinderAction(showFind)
        }
        if focusOnAppear { DispatchQueue.main.async { [weak view] in view?.window?.makeFirstResponder(view) } }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? SourceTextView else { return }
        view.isEditable = !disabled
        if view.string != text {
            let range = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location))))
            view.undoManager?.removeAllActions()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeMarkdownEditor
        weak var view: SourceTextView?
        init(_ parent: NativeMarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
        }
        func format(_ command: MarkdownEditing.Command) {
            guard !parent.disabled, let view else { return }
            let edit = MarkdownEditing.format(view.string, selection: view.selectedRange(), command: command)
            view.window?.makeFirstResponder(view)
            view.breakUndoCoalescing()
            view.insertText(edit.replacement, replacementRange: edit.replacementRange)
            view.setSelectedRange(edit.selection)
            view.scrollRangeToVisible(edit.selection)
            view.breakUndoCoalescing()
        }
    }
}

private final class SourceTextView: NSTextView {
    var format: ((MarkdownEditing.Command) -> Void)?
    private let readingWidth: CGFloat = 740
    private let minimumMargin: CGFloat = 28
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let margin = max(minimumMargin, (newSize.width - readingWidth) / 2) - (textContainer?.lineFragmentPadding ?? 0)
        if textContainerInset.width != margin { textContainerInset = NSSize(width: margin, height: 20) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "k" {
            format?(.link); return true
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": format?(.bold); return true
            case "i": format?(.italic); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
#else
private struct NativeMarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var disabled: Bool
    var focusOnAppear: Bool
    let actions: MarkdownEditorActions
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> SourceTextView {
        let view = SourceTextView()
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocorrectionType = .no
        view.autocapitalizationType = .sentences
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view.delegate = context.coordinator
        view.text = text
        view.isEditable = !disabled
        view.accessibilityLabel = "Markdown source"
        view.isFindInteractionEnabled = true
        view.inputAccessoryView = keyboardToolbar(view: view, coordinator: context.coordinator)
        context.coordinator.view = view
        view.format = { [weak coordinator = context.coordinator] in coordinator?.format($0) }
        actions.format = { [weak coordinator = context.coordinator] in coordinator?.format($0) }
        actions.find = { [weak view] in view?.findInteraction?.presentFindNavigator(showingReplace: false) }
        if focusOnAppear { DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() } }
        return view
    }
    private func keyboardToolbar(view: UITextView, coordinator: Coordinator) -> UIToolbar {
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.items = formattingTools.map { tool in
            let item = UIBarButtonItem(image: UIImage(systemName: tool.icon),
                                       primaryAction: UIAction { [weak coordinator] _ in coordinator?.format(tool.command) })
            item.accessibilityLabel = tool.title
            return item
        } + [.flexibleSpace(), UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak view] _ in view?.resignFirstResponder() })]
        toolbar.sizeToFit()
        return toolbar
    }
    func updateUIView(_ view: SourceTextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = !disabled
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location)))
            view.undoManager?.removeAllActions()
        }
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeMarkdownEditor
        weak var view: SourceTextView?
        init(_ parent: NativeMarkdownEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func format(_ command: MarkdownEditing.Command) {
            guard !parent.disabled, let view else { return }
            let edit = MarkdownEditing.format(view.text, selection: view.selectedRange, command: command)
            view.becomeFirstResponder()
            guard let start = view.position(from: view.beginningOfDocument, offset: edit.replacementRange.location),
                  let end = view.position(from: start, offset: edit.replacementRange.length),
                  let range = view.textRange(from: start, to: end) else { return }
            view.replace(range, withText: edit.replacement)
            view.selectedRange = edit.selection
            parent.text = view.text
            view.scrollRangeToVisible(edit.selection)
        }
    }
}
private final class SourceTextView: UITextView {
    var format: ((MarkdownEditing.Command) -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(boldMarkdown)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italicMarkdown)),
            UIKeyCommand(input: "k", modifierFlags: [.command, .shift], action: #selector(linkMarkdown))
        ]
    }
    @objc private func boldMarkdown() { format?(.bold) }
    @objc private func italicMarkdown() { format?(.italic) }
    @objc private func linkMarkdown() { format?(.link) }
}
#endif
