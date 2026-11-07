import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private actor CreationTransport: HTTPTransport {
    private var created = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.contains("/remote.php/") {
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"new\""])!)
        }
        let root = #"{"id":1,"title":"Team","fileName":"Readme.md","filePath":"","parentId":0,"collectivePath":"Collectives/Team"}"#
        let page = #"{"id":2,"title":"Ideas","fileName":"Ideas.md","filePath":"","parentId":1,"collectivePath":"Collectives/Team"}"#
        if request.httpMethod == "POST" { created = true }
        let payload = request.httpMethod == "POST" ? "{\"page\":\(page)}" : "{\"pages\":[\(root)\(created ? "," + page : "")]}"
        let body = "{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":\(payload)}}"
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Test
func createdPageOpensInEditModeWhenViewIsTheDefault() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "EditingFlowTests.\(root.lastPathComponent)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    defaults.set("preview", forKey: "defaultPageMode")
    let account = Account(serverURL: URL(string: "https://cloud.invalid")!, userID: "alice")
    let model = AppModel(store: LocalStore(root: root), modePreferences: PageModePreferences(defaults: defaults), makeClient: {
        CollectivesClient(account: $0, credential: Credential(loginName: "alice", appPassword: "test"), transport: CreationTransport())
    })
    model.accounts = [account]; model.activeID = account.id; model.selectedCollective = 7
    model.snapshot.collectives = [Collective(id: 7, name: "Team", canEdit: true)]
    try await model.createPage(title: "Ideas", parentID: 1, collectiveID: 7, accountID: account.id)
    #expect(model.selectedPage?.id == 2)
    #expect(model.pageMode == .edit)
    #expect(model.text.isEmpty)
    #expect(PageModePreferences(defaults: defaults).modeForPage(canEdit: true, hasConflict: false) == .view)
}
