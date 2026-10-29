// macOS integration smoke: actual bundled Text in an offline local-file WKWebView.
// Optional second argument sets the viewport width, e.g. 390 for phone toolbar layout.
import AppKit
import WebKit

@MainActor
final class Smoke: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var view: WKWebView!
    var timeout: Timer?
    var session = UUID().uuidString
    var stage = 0
    var openedAt = Date()
    var coldStart = Date()
    let source = "# Offline 📝\n\nOriginal **bold** text.\n"
    var edits = [String]()
    var loaded = false
    var editing = false
    let root: URL

    init(root: URL) { self.root = root }
    func run() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "textEditor")
        configuration.userContentController.add(self, name: "diagnostics")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            console.error = (...args) => window.webkit.messageHandlers.diagnostics.postMessage(args.map(String).join(' '));
            window.addEventListener('error', event => window.webkit.messageHandlers.diagnostics.postMessage(event.message));
            window.addEventListener('unhandledrejection', event => window.webkit.messageHandlers.diagnostics.postMessage(String(event.reason)));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: CGFloat(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 900 : 900), height: 700), configuration: configuration)
        view.navigationDelegate = self
        coldStart = Date()
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            print("FAIL: Offline editor timed out"); exit(1)
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "diagnostics" { fail("JavaScript: \(message.body)") }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { fail("Invalid bridge message") }
        switch type {
        case "warmed":
            print("Text runtime warm after \(Int(Date().timeIntervalSince(coldStart) * 1000)) ms")
        case "ready":
            openedAt = Date()
            view.callAsyncJavaScript("""
                const editor = await window.startTextEditor(input);
                await new Promise(resolve => setTimeout(resolve, 25));
                window.webkit.messageHandlers.textEditor.postMessage({type:'editing',session:input.session});
                if (document.querySelector('.ProseMirror').getAttribute('contenteditable') !== 'true') throw new Error('Editor is read-only after opening');
                const surface = document.querySelector('.ProseMirror');
                if (getComputedStyle(surface).cursor !== 'text') throw new Error('Editable text must show a text cursor');
                if (parseFloat(getComputedStyle(surface).fontSize) < 16) throw new Error('Editor text is small enough to trigger iOS focus zoom');
                const viewport = document.querySelector('meta[name="viewport"]').content;
                if (/user-scalable\\s*=\\s*no|maximum-scale\\s*=/.test(viewport)) throw new Error('Manual zoom must remain available');
                if (!getComputedStyle(document.documentElement).getPropertyValue('--color-primary-element-hover')) throw new Error('Nextcloud theme variables are missing');
                if (getComputedStyle(document.body.appendChild(document.createElement('ul'))).listStyleType !== 'none') throw new Error('Nextcloud list reset is missing, menus show bullets');
                editor.insertAtCursor(' Offline edit 日本語');
                const retainedHTML = editor.getHTML();
                await window.finishTextEditor({retainContent:true});
                if (editor.getHTML() !== retainedHTML || !document.getElementById('editor').inert) throw new Error('Retained page disappeared or accepted input');
                if (document.querySelector('.ProseMirror').getAttribute('contenteditable') !== 'false') throw new Error('Closed editor remained editable');
                return null;
                """, arguments: ["input": ["session": session, "markdown": source]], in: nil, in: .page) { result in
                if case .failure(let error) = result { self.fail("Boot/input failed: \(error)") }
            }
        case "loaded":
            guard edits.isEmpty else { fail("Loading changed source") }
            loaded = true
            print("Page \(stage + 1) ready after \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms")
        case "editing": editing = true
        case "update":
            guard loaded, editing, body["session"] as? String == session, let markdown = body["markdown"] as? String else { fail("Invalid update loaded=\(loaded): \(body)") }
            edits.append(markdown)
        case "finished":
            if stage == 0 {
                guard loaded, edits.last?.contains("Offline edit 日本語") == true,
                      edits.last?.contains("**bold**") == true else { fail("Rich input did not round-trip") }
                stage = 1; session = UUID().uuidString; loaded = false; editing = false; edits = []; openedAt = Date()
                view.callAsyncJavaScript("""
                    const editor = await window.startTextEditor(input);
                    await new Promise(resolve => setTimeout(resolve, 25));
                    const html = editor.getHTML();
                    if (html.includes('Offline edit')) throw new Error('Previous content leaked into the next page');
                    const state = editor.resetMarkdownContent(input.markdown, true);
                    if (!state.editable || document.querySelector('.ProseMirror').getAttribute('contenteditable') !== 'true') throw new Error('Reused editor is read-only');
                    if (state.canUndo || state.canRedo) throw new Error('Previous page undo/redo history leaked');
                    if (editor.getHTML() !== html) throw new Error('Reset changed rendered content');
                    window.scrollTo(0, 1e5);
                    const content = document.querySelector('.editor__content-wrapper');
                    content.scrollTop = 1e5;
                    await new Promise(resolve => setTimeout(resolve, 25));
                    if (content.scrollTop === 0) throw new Error('Long page did not scroll inside the content area');
                    if (window.scrollY !== 0 || document.querySelector('.text-menubar').getBoundingClientRect().top !== 0) throw new Error('Menubar scrolled out of view');
                    await window.finishTextEditor();
                    return null;
                    """, arguments: ["input": ["session": session, "markdown": "# Second page\n\nExact **source**\n" + String(repeating: "\nLong page paragraph\n", count: 80)]], in: nil, in: .page) { result in
                    if case .failure(let error) = result { self.fail("Reuse failed: \(error)") }
                }
            } else {
                guard loaded, edits.isEmpty else { fail("Page reuse rewrote source or leaked prior edits") }
                timeout?.invalidate()
                print("PASS: Offline Text cold/warm startup, rich Unicode edit, Markdown serialization, and retained-content page handoff, blocked stale input, and clean next-page source/history.")
                exit(0)
            }
        case "error": fail("Offline editor reported a runtime failure: \(body)")
        default: fail("Unexpected bridge message: \(type)")
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("Navigation failed: \(error)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("Web process terminated") }
    func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
}
MainActor.assumeIsolated {
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let smoke = Smoke(root: root)
smoke.run()
application.run()
}
