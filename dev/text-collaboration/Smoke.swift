import AppKit
import WebKit

enum SpikeError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SpikeError.failed(message) }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class Server {
    let base: URL
    let user: String
    private var password: String
    private let redirects = NoRedirects()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }()

    init(base: URL, user: String, password: String) {
        self.base = base; self.user = user; self.password = password
    }

    func request(_ method: String, _ path: String, body: Data? = nil,
                 headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var url = base
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Basic " + Data((user + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpikeError.failed("Non-HTTP response") }
        return (data, http)
    }

    func json(_ method: String, _ path: String, _ body: [String: Any] = [:]) async throws -> (Int, [String: Any]) {
        let encoded = method == "GET" ? nil : try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method, path, body: encoded)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (response.statusCode, object)
    }

    func useAppPassword() async throws {
        let (status, result) = try await json("GET", "ocs/v2.php/core/getapppassword")
        guard status == 200, let ocs = result["ocs"] as? [String: Any],
              let data = ocs["data"] as? [String: Any], let value = data["apppassword"] as? String,
              !value.isEmpty else { throw SpikeError.failed("Could not obtain test app password (HTTP \(status))") }
        password = value
    }

    var davRoot: String { "remote.php/dav/files/\(user)" }
}

@MainActor
final class Peer: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, WKNavigationDelegate {
    let name: String
    let server: Server
    let root: URL
    let fileID: Int
    let recovery: URL
    var view: WKWebView!
    var ready = false
    var offline = false
    var holdSaves = false
    var failure: String?
    var counts: [String: Int] = [:]
    var rejectedStatuses: [Int] = []
    private var documentID: String?
    private var sessionID: Int?
    private var sessionToken: String?
    private var baseVersionEtag: String?
    private var closing = false

    init(name: String, server: Server, root: URL, fileID: Int, recovery: URL) {
        self.name = name; self.server = server; self.root = root
        self.fileID = fileID; self.recovery = recovery
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "textTransport")
        config.userContentController.add(self, name: "textEditor")
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        view.navigationDelegate = self
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard trusted(message), let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "ready" { ready = true }
        if body["type"] as? String == "error" {
            failure = "\(name): JavaScript \(body["code"] ?? "error") at \(body["source"] ?? "unknown"):\(body["line"] ?? 0)"
        }
    }

    private func trusted(_ message: WKScriptMessage) -> Bool {
        message.frameInfo.isMainFrame && message.webView === view
            && view.url?.standardizedFileURL == root.appendingPathComponent("index.html").standardizedFileURL
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard trusted(message), let input = message.body as? [String: Any],
              let operation = input["operation"] as? String,
              ["create", "sync", "push", "save", "close"].contains(operation),
              let body = input["body"] as? [String: Any],
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count < 4 * 1024 * 1024
        else { replyHandler(nil, "Invalid native transport request"); return }
        Task {
            do { replyHandler(try await perform(operation, body), nil) }
            catch { replyHandler(nil, "Native transport failed"); failure = "\(name): native transport failed" }
        }
    }

    private func perform(_ operation: String, _ input: [String: Any]) async throws -> [String: Any] {
        counts[operation, default: 0] += 1
        if offline { return ["status": 503, "data": [:]] }
        if holdSaves && operation == "save" { return ["status": 503, "data": [:]] }
        let path: String
        var body: [String: Any] = [:]
        if operation == "create" {
            guard documentID == nil, !closing else { return ["status": 409, "data": [:]] }
            path = "index.php/apps/text/session/file/\(fileID)/create"
        } else {
            guard !closing || operation == "close", let documentID, let sessionID, let sessionToken,
                  input["documentId"] as? String == documentID,
                  input["sessionId"] as? Int == sessionID,
                  input["sessionToken"] as? String == "native-owned"
            else { return ["status": 403, "data": [:]] }
            path = "index.php/apps/text/session/\(documentID)/\(operation)"
            body = ["documentId": documentID, "sessionId": sessionID, "sessionToken": sessionToken]
            if operation != "close" {
                guard let version = input["version"] as? Int, version >= -1 else { return ["status": 400, "data": [:]] }
                body["version"] = version; body["baseVersionEtag"] = baseVersionEtag
                for key in ["steps", "awareness", "recoveryAttempt", "autosaveContent", "documentState", "manualSave"] {
                    body[key] = input[key]
                }
                body["force"] = false
            } else { closing = true }
        }
        let (status, received) = try await server.json(operation == "create" ? "PUT" : "POST", path, body)
        if status >= 400 { rejectedStatuses.append(status) }
        var result = received
        if operation == "create", status == 200 {
            guard let doc = result["document"] as? [String: Any],
                  let id = doc["id"] as? String, !id.isEmpty,
                  !id.contains("/"), !id.contains("\\"), id != ".", id != "..",
                  let base = doc["baseVersionEtag"] as? String,
                  var session = result["session"] as? [String: Any],
                  let sid = session["id"] as? Int, let token = session["token"] as? String
            else { throw SpikeError.failed("Unexpected Text 10 session response") }
            documentID = id; sessionID = sid; sessionToken = token; baseVersionEtag = base
            session["token"] = "native-owned"; result["session"] = session
        }
        return ["status": status, "data": result]
    }

    func js(_ expression: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        if let failure { throw SpikeError.failed(failure) }
        return try await view.callAsyncJavaScript(expression, arguments: arguments, in: nil, contentWorld: .page)
    }
    func state() async throws -> [String: Any] {
        try await js("return window.spike.state()") as? [String: Any] ?? [:]
    }
    func checkpoint() async throws {
        guard let snapshot = try await js("return window.spike.checkpoint()") as? [String: Any] else {
            throw SpikeError.failed("Could not checkpoint \(name)")
        }
        let data: [String: Any] = ["server": server.base.absoluteString, "user": server.user,
            "fileID": fileID, "baseVersionEtag": baseVersionEtag ?? "", "textRevision": "e3c02e800c15002323124ca118849316416faebb",
            "snapshot": snapshot]
        try JSONSerialization.data(withJSONObject: data).write(to: recovery, options: .atomic)
    }
    func expireSession() async throws {
        guard let documentID, let sessionID, let sessionToken else { throw SpikeError.failed("No session to expire") }
        let (status, _) = try await server.json("POST", "index.php/apps/text/session/\(documentID)/close",
            ["documentId": documentID, "sessionId": sessionID, "sessionToken": sessionToken])
        try require(status == 200, "Could not close session on server")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.standardizedFileURL == root.appendingPathComponent("index.html").standardizedFileURL ? .allow : .cancel
    }
}

@MainActor
final class Smoke {
    let server: Server
    let root: URL
    let output: URL
    var peers: [Peer] = []
    var probe: Peer?
    var fixtures: [String] = []

    init() throws {
        let args = CommandLine.arguments
        try require(args.count == 3, "Usage: text-collaboration-smoke RUNTIME_DIRECTORY SERVER_URL")
        root = URL(fileURLWithPath: args[1]).standardizedFileURL
        output = root.deletingLastPathComponent()
        guard let url = URL(string: args[2]), url.scheme == "http", ["localhost", "127.0.0.1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw SpikeError.failed("This disposable spike accepts loopback HTTP servers only")
        }
        server = Server(base: url, user: "spike", password: "local-spike-only")
    }

    func wait(_ label: String, seconds: Double = 25, check: () async throws -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        for peer in peers {
            let state = try? await peer.state()
            print("\(peer.name) timeout state: version=\(state?["version"] ?? "?") saved=\(state?["savedVersion"] ?? "?") loaded=\(state?["loaded"] ?? "?") error=\(state?["error"] ?? "none") requests=\(peer.counts)")
        }
        throw SpikeError.failed("Timed out: \(label)")
    }

    func run() async throws {
        try await server.useAppPassword()
        print("PASS: Native app-password authentication")
        try await noEditProbe()
        let initial = "# Native collaboration\n\nShared starting text.\n"
        let (path, fileID) = try await createFixture(initial)
        for name in ["A", "B"] {
            peers.append(Peer(name: name, server: server, root: root, fileID: fileID,
                              recovery: output.appendingPathComponent("recovery-\(name).json")))
        }
        let a = peers[0], b = peers[1]
        try await wait("WebKit runtimes") { peers.allSatisfy(\.ready) }
        for peer in peers { _ = try await peer.js("await window.spike.start(fileID); return null", ["fileID": fileID]) }
        try await wait("initial sync") {
            for peer in peers {
                let state = try await peer.state()
                if state["loaded"] as? Bool != true || !(state["markdown"] as? String ?? "").contains("Shared starting text.") { return false }
            }
            return true
        }
        print("PASS: Two isolated WKWebViews joined real Text sessions")
        let isolated = try await a.js("""
            const response = await window.webkit.messageHandlers.textTransport.postMessage({
                operation: 'push', body: { documentId: 'another-document', sessionId: 1,
                    sessionToken: 'another-session', version: 0, steps: [], awareness: '' },
            });
            return response.status === 403;
            """) as? Bool
        try require(isolated == true, "Bridge accepted another document/session identity")
        print("PASS: Native bridge rejects foreign document/session identity")
        try await exerciseCollaboration(path: path, a: a, b: b)
    }

    func createFixture(_ initial: String) async throws -> (String, Int) {
        let path = server.davRoot + "/Native collaboration \(UUID().uuidString).md"
        fixtures.append(path)
        let (_, put) = try await server.request("PUT", path, body: Data(initial.utf8), headers: ["If-None-Match": "*", "Content-Type": "text/markdown"])
        try require(put.statusCode == 201, "Could not create disposable fixture (HTTP \(put.statusCode))")
        let propfind = Data("<d:propfind xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\"><d:prop><oc:fileid/></d:prop></d:propfind>".utf8)
        let (xml, prop) = try await server.request("PROPFIND", path, body: propfind, headers: ["Depth": "0", "Content-Type": "application/xml"])
        let text = String(decoding: xml, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: "<(?:[A-Za-z0-9]+:)?fileid>([0-9]+)</")
        guard prop.statusCode == 207, let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let fileID = Int(text[range]) else { throw SpikeError.failed("Missing DAV file ID") }
        return (path, fileID)
    }

    func noEditProbe() async throws {
        let original = "# Source preservation\n\n<custom-native-spike data-value=\"untouched\">Opaque source</custom-native-spike>\n\n<!-- retain this exact comment -->\n"
        let (path, fileID) = try await createFixture(original)
        let peer = Peer(name: "No-edit", server: server, root: root, fileID: fileID,
                        recovery: output.appendingPathComponent("recovery-no-edit.json"))
        probe = peer
        try await wait("no-edit runtime") { peer.ready }
        _ = try await peer.js("await window.spike.start(fileID); return null", ["fileID": fileID])
        try await wait("no-edit load") { try await peer.state()["loaded"] as? Bool == true }
        // Give the upstream debounce a chance to reveal accidental autosaves.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        _ = try await peer.js("return await window.spike.close()")
        let (body, response) = try await server.request("GET", path)
        try require(response.statusCode == 200 && String(decoding: body, as: UTF8.self) == original,
                    "Opening/closing rewrote unsupported source")
        try require(peer.counts["save", default: 0] == 0, "No-edit opening issued a file save")
        probe = nil
        print("PASS: No-edit open/close preserves opaque HTML/comments without a file-save request")
    }

    func exerciseCollaboration(path: String, a: Peer, b: Peer) async throws {
        // Suppress file saves to distinguish collaboration from persistence.
        a.holdSaves = true; b.holdSaves = true
        _ = try await a.js("return window.spike.append(text)", ["text": " Native-A-α"])
        _ = try await b.js("return window.spike.append(text)", ["text": " Native-B-日本語"])
        for peer in peers { try await peer.checkpoint() }
        try await wait("concurrent convergence") { try await converged(["Native-A-α", "Native-B-日本語"]) }
        let (unsaved, _) = try await server.request("GET", path)
        try require(!String(decoding: unsaved, as: UTF8.self).contains("Native-A-α"), "Push unexpectedly counted as a file save")
        print("PASS: Concurrent Unicode edits converge; pushed changes are distinct from DAV saves")
        b.offline = true
        _ = try await b.js("return window.spike.append(text)", ["text": " Offline-B"])
        try await b.checkpoint()
        _ = try await a.js("return window.spike.append(text)", ["text": " Online-A"])
        try await a.checkpoint()
        try await Task.sleep(nanoseconds: 700_000_000)
        b.offline = false
        _ = try await b.js("window.spike.reconnect(); return null")
        try await wait("reconnect convergence") { try await converged(["Native-A-α", "Native-B-日本語", "Offline-B", "Online-A"]) }
        print("PASS: Offline peer rejoins without replacing the shared Y.Doc")
        for peer in peers { _ = try await peer.js("return await window.spike.drain()") }
        try await wait("drained convergence") { try await converged(["Offline-B", "Online-A"]) }
        a.holdSaves = false
        let saved = try await a.js("return await window.spike.save()") as? [String: Any] ?? [:]
        try require((saved["savedVersion"] as? Int ?? -2) >= (saved["version"] as? Int ?? -1), "HTTP success did not confirm the saved version")
        let (canonical, response) = try await server.request("GET", path)
        try require(response.statusCode == 200 && response.value(forHTTPHeaderField: "ETag") != nil, "No canonical Markdown/ETag after save")
        try require(String(decoding: canonical, as: UTF8.self) == saved["markdown"] as? String, "DAV Markdown differs from converged document")
        print("PASS: Explicit save acknowledged version and canonical DAV Markdown/ETag")
        // End one server session behind the editor, then prove rejection retains work.
        try await b.expireSession()
        // append() is a harness command even when the surface is frozen.
        _ = try await b.js("return window.spike.append(text)", ["text": " Recovery-after-expiry"])
        try await b.checkpoint()
        try await wait("expired-session rejection") {
            b.rejectedStatuses.contains(403) || b.rejectedStatuses.contains(412)
        }
        let backup = try Data(contentsOf: b.recovery)
        try require(String(decoding: backup, as: UTF8.self).contains("Recovery-after-expiry"), "Lost rejected-session work")
        print("PASS: Server session expiry preserves a native Markdown/Yjs recovery checkpoint")
        _ = try await a.js("return await window.spike.close()")
        let (_, sourceWrite) = try await server.request("PUT", path, body: canonical,
            headers: ["If-Match": response.value(forHTTPHeaderField: "ETag")!, "Content-Type": "text/markdown"])
        try require([200, 204].contains(sourceWrite.statusCode), "Conditional DAV handoff failed (HTTP \(sourceWrite.statusCode))")
        print("PASS: Session close followed by conditional DAV handoff")
        let report: [String: Any] = ["textRevision": "e3c02e800c15002323124ca118849316416faebb", "textVersion": "10.0.0-dev.3",
            "server": "Nextcloud 36-dev", "passed": true, "nativeRequests": peers.map { ["peer": $0.name, "counts": $0.counts] }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"), options: .atomic)
    }

    func converged(_ markers: [String]) async throws -> Bool {
        let states = try await peers.asyncStates()
        let texts = states.compactMap { $0["markdown"] as? String }
        return texts.count == 2 && texts[0] == texts[1] && markers.allSatisfy { texts[0].contains($0) }
            && states.allSatisfy { $0["pending"] as? Bool == false }
    }

    func cleanup() async {
        for peer in peers + (probe.map { [$0] } ?? []) {
            try? await peer.checkpoint()
            _ = try? await peer.js("return await window.spike.close()")
        }
        for fixture in fixtures { _ = try? await server.request("DELETE", fixture) }
    }
}

extension Array where Element == Peer {
    @MainActor func asyncStates() async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for peer in self { result.append(try await peer.state()) }
        return result
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        let smoke = try Smoke()
        do {
            try await smoke.run()
            await smoke.cleanup()
            print("PASS: Native Text collaboration spike")
            exit(0)
        } catch {
            print("FAIL: \(error)")
            await smoke.cleanup()
            exit(1)
        }
    } catch { print("FAIL: \(error)"); exit(1) }
}
app.run()
