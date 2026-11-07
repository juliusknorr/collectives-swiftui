import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private actor RecordingTransport: HTTPTransport {
    let listsNote: Bool
    private(set) var methods: [String] = []
    init(listsNote: Bool = true) { self.listsNote = listsNote }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        methods.append(request.httpMethod ?? "GET")
        if url.path.contains("/remote.php/") {
            return (Data("server".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"new\""])!)
        }
        let root = #"{"id":1,"title":"Team","fileName":"Readme.md","filePath":"","parentId":0}"#
        let note = #"{"id":2,"title":"Note","fileName":"Note.md","filePath":"","parentId":1}"#
        let body = "{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":{\"pages\":[\(root)\(listsNote ? "," + note : "")]}}}"
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private let note = Page(id: 2, title: "Note", fileName: "Note.md", filePath: "", collectivePath: "Collectives/Team", parentId: 1)

@MainActor
private func openNoteModel(transport: RecordingTransport, root: URL) -> AppModel {
    let account = Account(serverURL: URL(string: "https://cloud.invalid")!, userID: "alice")
    let model = AppModel(store: LocalStore(root: root), makeClient: {
        CollectivesClient(account: $0, credential: Credential(loginName: "alice", appPassword: "test"), transport: transport)
    })
    model.accounts = [account]; model.activeID = account.id; model.selectedCollective = 7
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 7, name: "Team", canEdit: true)]
    snapshot.pages["7"] = [Page(id: 1, title: "Team", fileName: "Readme.md", filePath: "", collectivePath: "Collectives/Team", parentId: 0), note]
    snapshot.documents["2"] = CachedDocument(page: note, collectiveID: 7, markdown: "Saved", etag: "\"base\"")
    model.snapshot = snapshot
    model.selectedPage = note; model.text = "Saved"
    return model
}

@MainActor @Test
func saveShortcutSyncsOnlyPagesWithLocalChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = RecordingTransport()
    let model = openNoteModel(transport: transport, root: root)
    await model.syncLocalChanges()
    #expect(await transport.methods.isEmpty)
    #expect(model.text == "Saved")

    model.snapshot.documents["2"]?.draft = "Typed"
    await model.syncLocalChanges()
    #expect(await transport.methods.contains("PUT"))
    #expect(model.document?.draft == nil)
    #expect(model.document?.markdown == "Typed")
}

@MainActor @Test
func refreshingPagesKeepsTheOpenPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = openNoteModel(transport: RecordingTransport(), root: root)
    #expect(await model.openCollective(7))
    #expect(model.selectedPage?.id == 2)
    #expect(model.text == "Saved")

    let removed = openNoteModel(transport: RecordingTransport(listsNote: false), root: root)
    #expect(await removed.openCollective(7))
    #expect(removed.selectedPage == nil)
    #expect(removed.text.isEmpty)
}

@MainActor @Test
func restoreSourceIsOfferedOnlyWithABackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = openNoteModel(transport: RecordingTransport(), root: root)
    #expect(!model.hasTextSourceBackup)
    model.snapshot.rememberTextSource(pageID: 2, markdown: "Before Text")
    #expect(model.hasTextSourceBackup)
}
