import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private actor OrganizationTransport: HTTPTransport {
    private var moved = false
    private(set) var writes = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "PUT" { moved = true; writes += 1 }
        let root = #"{"id":1,"title":"Team","fileName":"Readme.md","filePath":"","parentId":0}"#
        let destination = #"{"id":3,"title":"Destination","fileName":"Readme.md","filePath":"Destination","parentId":1}"#
        let page = """
        {"id":2,"title":"Note","fileName":"Note.md","filePath":"\(moved ? "Destination" : "")","parentId":\(moved ? 3 : 1),"collectivePath":"Collectives/Team"}
        """
        let payload = request.httpMethod == "PUT" ? "{\"page\":\(page)}" : "{\"pages\":[\(root),\(page),\(destination)]}"
        let body = "{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":\(payload)}}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Test
func movePublishesPathsAcrossWindowsAndPreservesDraftOnDisk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStore(root: root)
    let transport = OrganizationTransport()
    let account = Account(serverURL: URL(string: "https://cloud.invalid")!, userID: "alice")
    let model = AppModel(store: store, makeClient: {
        CollectivesClient(account: $0, credential: Credential(loginName: "alice", appPassword: "test"), transport: transport)
    })
    model.accounts = [account]; model.activeID = account.id; model.selectedCollective = 7
    let page = Page(id: 2, title: "Note", fileName: "Note.md", filePath: "", collectivePath: "Collectives/Team", parentId: 1)
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 7, name: "Team", canEdit: true)]
    snapshot.pages["7"] = [page]
    snapshot.documents["2"] = CachedDocument(page: page, collectiveID: 7, markdown: "base", etag: "\"base\"", draft: "local draft")
    model.snapshot = snapshot; model.selectedPage = page; model.text = "local draft"
    let observer = model.newWindow()
    observer.activeID = account.id; observer.selectedCollective = 7; observer.selectedPage = page; observer.text = "local draft"
    try await model.movePage(pageID: 2, parentID: 3,
        request: PageOrganizationRequest(accountID: account.id, collectiveID: 7, action: .move(page)))
    #expect(await transport.writes == 1)
    #expect(observer.selectedPage?.filePath == "Destination")
    #expect(observer.text == "local draft")
    let saved = try await store.snapshot(accountID: account.id)
    #expect(saved.documents["2"]?.page.filePath == "Destination")
    #expect(saved.documents["2"]?.draft == "local draft")
    #expect(saved.documents["2"]?.etag == "\"base\"")
    #expect(saved.documents["2"]?.markdown == "base")
}

@MainActor @Test
func pageOrganizationRejectsStaleAccountAndOtherWindowEditor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: LocalStore(root: root))
    let account = Account(serverURL: URL(string: "https://cloud.invalid")!, userID: "alice")
    model.accounts = [account]; model.activeID = account.id; model.selectedCollective = 7
    model.snapshot.collectives = [Collective(id: 7, name: "Team", canEdit: true)]
    let page = Page(id: 2, title: "Note", fileName: "Note.md", filePath: "", collectivePath: "Collectives/Team", parentId: 1)
    await #expect(throws: (any Error).self) {
        try await model.trashPage(pageID: 2,
            request: PageOrganizationRequest(accountID: UUID(), collectiveID: 7, action: .trash(page)))
    }
    let other = model.newWindow()
    other.activeID = account.id; other.selectedCollective = 7; other.pageMode = .edit
    await #expect(throws: (any Error).self) {
        try await model.trashPage(pageID: 2,
            request: PageOrganizationRequest(accountID: account.id, collectiveID: 7, action: .trash(page)))
    }
    #expect(!model.busy)
}
