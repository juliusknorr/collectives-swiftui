import SwiftUI
import CollectivesCore
@preconcurrency import WebKit

struct OfflineTextSheet: View {
    @Bindable var model: AppModel
    let session: EmbeddedTextSession
    @State private var loaded = false
    @State private var failed = false
    @State private var closing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nextcloud Text · Experimental").font(.headline)
                    Text("Offline editing · Original source backed up · Sync paused").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(closing ? "Saving…" : "Done") {
                    if failed || !loaded { finish() } else { closing = true }
                }.disabled(closing).keyboardShortcut(.defaultAction)
            }.padding()
            Divider()
            OfflineTextWebView(session: session, closing: closing,
                onLoaded: { loaded = true }, onError: { failed = true; closing = false },
                onUpdate: { revision, markdown in
                    model.textEdited(sessionID: session.id, revision: revision, markdown: markdown)
                }, onFinished: finish)
            if failed {
                Text("Text could not load or stopped responding. Close this editor to use Markdown source. Previously received edits remain in your local draft.")
                    .foregroundStyle(.red).padding()
            }
            Divider()
            Text(model.message).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(minWidth: 360, idealWidth: 1000, minHeight: 500, idealHeight: 760)
    }
    private func finish() {
        closing = true
        Task { await model.finishTextEditing() }
    }
}

@MainActor
private struct OfflineTextWebView {
    let session: EmbeddedTextSession
    let closing: Bool
    let onLoaded: () -> Void
    let onError: () -> Void
    let onUpdate: (Int, String) -> Void
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    func makeWebView(context: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context, name: "textEditor")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context
        context.webView = view
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("EmbeddedText"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else {
            Task { @MainActor in onError() }; return view
        }
        context.indexURL = root.appendingPathComponent("index.html").standardizedFileURL
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        return view
    }

    @MainActor
    func update(_ view: WKWebView, coordinator: Coordinator) {
        guard closing, !coordinator.closing else { return }
        coordinator.closing = true
        view.evaluateJavaScript("window.finishTextEditor()") { _, error in
            if error != nil { onError() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let host: OfflineTextWebView
        weak var webView: WKWebView?
        var indexURL: URL?
        var started = false
        var closing = false
        init(_ host: OfflineTextWebView) { self.host = host }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.webView?.url?.standardizedFileURL == indexURL,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready", !started {
                started = true
                Task { @MainActor in
                    do {
                        _ = try await webView?.callAsyncJavaScript("await window.startTextEditor(input)", arguments: ["input": [
                            "session": host.session.id.uuidString, "markdown": host.session.initialMarkdown
                        ]], in: nil, contentWorld: .page)
                    } catch { host.onError() }
                }
                return
            }
            if type == "error" { host.onError(); return }
            guard body["session"] as? String == host.session.id.uuidString else { return }
            switch type {
            case "loaded": host.onLoaded()
            case "update":
                guard let revision = body["revision"] as? Int, let markdown = body["markdown"] as? String else { return }
                host.onUpdate(revision, markdown)
            case "finished": host.onFinished()
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.standardizedFileURL == indexURL ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { host.onError() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { host.onError() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { host.onError() }
    }
}

#if os(macOS)
extension OfflineTextWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "textEditor")
    }
}
#else
extension OfflineTextWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "textEditor")
    }
}
#endif
