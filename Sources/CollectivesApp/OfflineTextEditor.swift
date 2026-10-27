import SwiftUI
import CollectivesCore
@preconcurrency import WebKit

/// One local runtime, warmed at launch and reused without retaining page undo history.
@MainActor @Observable
final class OfflineTextRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var loaded = false
    private(set) var failed = false
    private(set) var warmed = false
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var indexURL: URL?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var session: EmbeddedTextSession?
    @ObservationIgnored private var onUpdate: ((Int, String) -> Void)?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?

    func warm() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "textEditor")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        loadAssets()
    }
    private func loadAssets() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("EmbeddedText"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else { fail(); return }
        ready = false; loaded = false; warmed = false; failed = false; launched = false
        indexURL = root.appendingPathComponent("index.html").standardizedFileURL
        webView?.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }
    func start(_ session: EmbeddedTextSession, onUpdate: @escaping (Int, String) -> Void) {
        warm()
        if failed { loadAssets() }
        self.session = session; self.onUpdate = onUpdate
        loaded = false; launched = false
        launchIfReady()
    }
    private func launchIfReady() {
        guard ready, !launched, let session else { return }
        launched = true
        webView?.callAsyncJavaScript("await window.startTextEditor(input)", arguments: ["input": [
            "session": session.id.uuidString, "markdown": session.initialMarkdown
        ]], in: nil, in: .page) { result in
            if case .failure = result, self.session?.id == session.id { self.fail() }
        }
    }

    func finish() async {
        guard session != nil else { return }
        if failed { clearSession(); return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
            guard !finishing else { return }
            finishing = true
            // A page can be switched before scripts finish loading. Once ready,
            // launchIfReady queues start before finish through the JS operation queue.
            if ready { sendFinish() }
            finishTimeout = Task {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, finishing else { return }
                fail()
                webView?.stopLoading()
            }
        }
    }
    private func sendFinish() {
        webView?.evaluateJavaScript("void window.finishTextEditor()") { _, error in
            if error != nil { self.fail() }
        }
    }
    private func clearSession() {
        finishTimeout?.cancel(); finishTimeout = nil
        session = nil; onUpdate = nil; loaded = false; finishing = false
        let waiters = finishWaiters; finishWaiters = []
        waiters.forEach { $0.resume() }
    }
    private func fail() {
        failed = true
        if finishing { clearSession() }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView?.url?.standardizedFileURL == indexURL,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true; launchIfReady()
            if finishing { sendFinish() }
        case "warmed": warmed = true
        case "error": fail()
        default:
            guard let session, body["session"] as? String == session.id.uuidString else { return }
            switch type {
            case "loaded": loaded = true
            case "update":
                guard let revision = body["revision"] as? Int, let markdown = body["markdown"] as? String else { return }
                onUpdate?(revision, markdown)
            case "finished": clearSession()
            default: break
            }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.standardizedFileURL == indexURL ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
}

@MainActor
struct OfflineTextPage: View {
    @Bindable var runtime: OfflineTextRuntime
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Rich Text · Experimental", systemImage: "textformat")
                Spacer()
                Text("Original source backed up · Sync paused")
            }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            ZStack {
                OfflineTextWebView(runtime: runtime).opacity(runtime.loaded ? 1 : 0).allowsHitTesting(runtime.loaded)
                if runtime.failed {
                    ContentUnavailableView("Rich Text Unavailable", systemImage: "exclamationmark.triangle",
                        description: Text("Switch to View or Edit. Saved edits and the original source are retained."))
                } else if !runtime.loaded {
                    ProgressView("Preparing rich text…")
                }
            }
        }
    }
}

@MainActor
private struct OfflineTextWebView {
    let runtime: OfflineTextRuntime
    func view() -> WKWebView { runtime.warm(); return runtime.webView! }
}
#if os(macOS)
extension OfflineTextWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { view() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension OfflineTextWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { view() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
