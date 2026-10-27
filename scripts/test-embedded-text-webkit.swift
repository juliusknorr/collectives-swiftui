// macOS integration smoke: actual bundled Text in an offline local-file WKWebView.
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
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
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
                editor.insertAtCursor(' Offline edit 日本語');
                await window.finishTextEditor();
                return null;
                """, arguments: ["input": ["session": session, "markdown": source]], in: nil, in: .page) { result in
                if case .failure(let error) = result { self.fail("Boot/input failed: \(error)") }
            }
        case "loaded":
            guard edits.isEmpty else { fail("Loading changed source") }
            loaded = true
            print("Page \(stage + 1) ready after \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms")
        case "update":
            guard loaded, body["session"] as? String == session, let markdown = body["markdown"] as? String else { fail("Invalid update loaded=\(loaded): \(body)") }
            edits.append(markdown)
        case "finished":
            if stage == 0 {
                guard loaded, edits.last?.contains("Offline edit 日本語") == true,
                      edits.last?.contains("**bold**") == true else { fail("Rich input did not round-trip") }
                stage = 1; session = UUID().uuidString; loaded = false; edits = []; openedAt = Date()
                view.callAsyncJavaScript("""
                    await window.startTextEditor(input);
                    await window.finishTextEditor();
                    return null;
                    """, arguments: ["input": ["session": session, "markdown": "# Second page\n\nExact **source**\n"]], in: nil, in: .page) { result in
                    if case .failure(let error) = result { self.fail("Reuse failed: \(error)") }
                }
            } else {
                guard loaded, edits.isEmpty else { fail("Page reuse rewrote source or leaked prior edits") }
                timeout?.invalidate()
                print("PASS: Offline Text cold/warm startup, rich Unicode edit, Markdown serialization, and second-page reuse without rewriting source.")
                exit(0)
            }
        case "error": fail("Offline editor reported a runtime failure")
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
