// Synthetic native/WebKit handoff benchmark. No server, credentials, or user notes.
import AppKit
import WebKit

private struct Fixture {
    let name: String
    let markdown: String
    let structured: Bool
    init(name: String, bytes: Int, structured: Bool = true) {
        self.name = name
        self.structured = structured
        var source = "# \(name) fixture [NOTE]\n\n"
        var section = 0
        while source.utf8.count < bytes {
            section += 1
            if !structured {
                if section % 10 == 1 { source += "## Section \(section)\n\n" }
                source += String(repeating: "Note [NOTE] has a paragraph with **bold**, *italic*, and `inline code`. ", count: 8) + "\n\n"
                continue
            }
            source += """
            ## Section \(section)

            Note [NOTE] has a paragraph with **bold**, *italic*, and `inline code` for editor layout.

            - [ ] First task [NOTE]
            - [x] Completed task [NOTE]

            | Name | Value |
            | --- | --- |
            | Example [NOTE] | 42 |

            """ + "\n"
        }
        markdown = source
    }
}
private struct Sample {
    let total: Double
    let finish: Double
    let reset: Double
}

@MainActor
private final class Benchmark: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let fixtures = [Fixture(name: "small-mixed", bytes: 1_024), Fixture(name: "medium-mixed", bytes: 10_240),
                    Fixture(name: "large-prose", bytes: 102_400, structured: false),
                    Fixture(name: "large-mixed", bytes: 102_400)]
    let rounds: Int
    let root: URL
    let output: URL
    var view: WKWebView!
    var timeout: Timer?
    var session = UUID().uuidString
    var iteration = -1
    var coldStarted = 0.0
    var switchStarted = 0.0
    var finishedAfter = 0.0
    var loadedAfter = 0.0
    var samples: [String: [Sample]] = [:]
    var coldReady = 0.0
    var receivedLoad = false

    init(root: URL, rounds: Int, output: URL) { self.root = root; self.rounds = rounds; self.output = output }
    private func now() -> Double { ProcessInfo.processInfo.systemUptime }
    private func elapsed(_ start: Double) -> Double { (now() - start) * 1_000 }
    func run() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "textEditor")
        configuration.userContentController.add(self, name: "benchmark")
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        view.navigationDelegate = self
        coldStarted = now()
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        timeout = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
            print("FAIL: Benchmark timed out"); exit(1)
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { fail("Malformed bridge message") }
        if message.name == "benchmark" {
            guard body["session"] as? String == session, receivedLoad,
                  let reset = body["resetMS"] as? Double else { fail("Invalid benchmark result") }
            if iteration < 0 {
                coldReady = elapsed(coldStarted)
            } else if iteration % (rounds + 1) > 0 {
                // Discard the first switch within each workload.
                let fixture = fixtures[iteration / (rounds + 1)]
                samples[fixture.name, default: []].append(Sample(total: loadedAfter, finish: finishedAfter, reset: reset))
            }
            advance()
            return
        }
        switch body["type"] as? String {
        case "ready": start(markdown: "# Warmup\n\nSynthetic initial note.\n")
        case "warmed": break
        case "loaded":
            guard body["session"] as? String == session else { fail("Stale loaded event") }
            receivedLoad = true
            loadedAfter = elapsed(switchStarted)
        case "finished":
            guard body["session"] as? String == session else { fail("Stale finish event") }
            finishedAfter = elapsed(switchStarted)
            session = UUID().uuidString
            let fixture = fixtures[iteration / (rounds + 1)]
            start(markdown: fixture.markdown.replacingOccurrences(of: "[NOTE]", with: iteration % 2 == 0 ? "Note A" : "Note B"))
        case "update": fail("Opening a fixture unexpectedly rewrote its source")
        case "error": fail("Editor error: \(body)")
        default: fail("Unexpected bridge event")
        }
    }
    private func start(markdown: String) {
        receivedLoad = false
        view.callAsyncJavaScript("""
            const started = performance.now();
            await window.startTextEditor(input);
            window.webkit.messageHandlers.benchmark.postMessage({
                session: input.session, resetMS: performance.now() - started
            });
            return null;
            """, arguments: ["input": ["session": session, "markdown": markdown]], in: nil, in: .page) { result in
            if case .failure(let error) = result { self.fail("Start bridge failed: \(error)") }
        }
    }
    private func advance() {
        iteration += 1
        if iteration == fixtures.count * (rounds + 1) { report(); return }
        switchStarted = now()
        view.callAsyncJavaScript("await window.finishTextEditor({retainContent:true}); return null;",
                                 arguments: [:], in: nil, in: .page) { result in
            if case .failure(let error) = result { self.fail("Finish bridge failed: \(error)") }
        }
    }
    private func statistics(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
        return ["median": percentile(0.5), "p95": percentile(0.95), "max": sorted.last!]
    }
    private func report() {
        timeout?.invalidate()
        var cases: [[String: Any]] = []
        print("Native finish/start handoff to the loaded callback; excludes SwiftUI, persistence, and paint.")
        print("Alternating distinct notes within each workload; first switch discarded; \(rounds) samples; milliseconds.")
        print("Fixture | KiB | Total median / p95 | Finish median | JS reset median")
        for fixture in fixtures {
            guard let values = samples[fixture.name], values.count == rounds else { fail("Missing samples") }
            let total = statistics(values.map(\.total))
            let finish = statistics(values.map(\.finish))
            let reset = statistics(values.map(\.reset))
            let size = Double(fixture.markdown.utf8.count) / 1_024
            print(String(format: "%@ | %.1f | %.1f / %.1f | %.1f | %.1f", fixture.name, size,
                         total["median"]!, total["p95"]!, finish["median"]!, reset["median"]!))
            cases.append(["name": fixture.name, "structured": fixture.structured,
                          "bytes": fixture.markdown.utf8.count, "samples": rounds,
                          "totalMS": total, "finishMS": finish, "resetJavaScriptMS": reset])
        }
        let provenance = (try? Data(contentsOf: root.appendingPathComponent("vendor/provenance.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let report: [String: Any] = ["metric": "native finish/start to loaded callback",
            "excluded": ["SwiftUI navigation", "draft persistence", "paint", "network", "pending edits"],
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "textRevision": provenance?["revision"] as? String ?? "unknown",
            "coldFirstNoteMS": coldReady, "cases": cases]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        } catch { fail("Could not save report: \(error)") }
        print("Report: \(output.path)")
        exit(0)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("Asset navigation failed") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail("Navigation failed") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("Web process terminated") }
    private func fail(_ reason: String) -> Never { print("FAIL: \(reason)"); exit(1) }
}

MainActor.assumeIsolated {
    guard CommandLine.arguments.count >= 2 else {
        print("Usage: benchmark-embedded-text ASSET_ROOT [ROUNDS] [REPORT_JSON]"); exit(2)
    }
    let rounds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 0 : 10
    guard (1...50).contains(rounds) else { print("Rounds must be between 1 and 50"); exit(2) }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ".build/embedded-text/benchmark-results.json")
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let benchmark = Benchmark(root: root, rounds: rounds, output: output)
    benchmark.run()
    application.run()
}
