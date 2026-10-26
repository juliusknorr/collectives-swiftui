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
}

struct MarkdownSourceEditor: View {
    @Binding var text: String
    var disabled: Bool
    @StateObject private var actions = MarkdownEditorActions()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tool("Heading", icon: "textformat.size", command: .heading)
                    tool("Bold", icon: "bold", command: .bold)
                    tool("Italic", icon: "italic", command: .italic)
                    Divider().frame(height: 18).padding(.horizontal, 4)
                    tool("Link", icon: "link", command: .link)
                    tool("Task", icon: "checklist", command: .task)
                    tool("Code", icon: "chevron.left.forwardslash.chevron.right", command: .code)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .disabled(disabled)
            Divider()
            NativeMarkdownEditor(text: $text, disabled: disabled, actions: actions)
        }
    }

    private func tool(_ title: String, icon: String, command: MarkdownEditing.Command) -> some View {
        Button { actions.format?(command) } label: {
            Image(systemName: icon).frame(minWidth: 28, minHeight: 26)
        }
        .accessibilityLabel(title)
        .help(title)
    }
}

#if os(macOS)
private struct NativeMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var disabled: Bool
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
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = NSSize(width: 20, height: 20)
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": format?(.bold); return true
            case "i": format?(.italic); return true
            case "k": format?(.link); return true
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
        context.coordinator.view = view
        view.format = { [weak coordinator = context.coordinator] in coordinator?.format($0) }
        actions.format = { [weak coordinator = context.coordinator] in coordinator?.format($0) }
        return view
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
            UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(linkMarkdown))
        ]
    }
    @objc private func boldMarkdown() { format?(.bold) }
    @objc private func italicMarkdown() { format?(.italic) }
    @objc private func linkMarkdown() { format?(.link) }
}
#endif
