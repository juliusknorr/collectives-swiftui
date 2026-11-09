import Foundation
import Testing
import CollectivesCore
@testable import CollectivesApp

private actor HeldDownloadTransport: HTTPTransport {
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var holding = true
    private(set) var paths: [String] = []
    func waitForHeldRequest() async {
        if held != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { holding = false; held?.resume(); held = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        paths.append(request.url!.path)
        if holding {
            await withCheckedContinuation { continuation in
                held = continuation
                waiter?.resume(); waiter = nil
            }
        }
        return (Data("body".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["ETag": "\"etag\""])!)
    }
}

@MainActor
private func navigationModel(transport: any HTTPTransport, pages: [Page], root: URL) -> (AppModel, Account) {
    let account = Account(serverURL: URL(string: "https://cloud.invalid")!, userID: "alice")
    let model = AppModel(store: LocalStore(root: root), makeClient: {
        CollectivesClient(account: $0, credential: Credential(loginName: "alice", appPassword: "test"), transport: transport)
    })
    model.accounts = [account]; model.activeID = account.id; model.selectedCollective = 7
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 7, name: "Team", canEdit: true)]
    snapshot.pages["7"] = pages
    model.snapshot = snapshot
    return (model, account)
}

@MainActor @Test
func latestPageTappedWhileOpeningWins() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pages = (1...3).map { Page(id: $0, title: "Page \($0)", fileName: "P\($0).md", filePath: "", collectivePath: "Collectives/Team", parentId: 0) }
    let transport = HeldDownloadTransport()
    let (model, _) = navigationModel(transport: transport, pages: pages, root: root)
    let first = Task { await model.openPage(pages[0]) }
    await transport.waitForHeldRequest()
    await model.openPage(pages[1])
    await model.openPage(pages[2])
    #expect(model.queuedPage?.id == 3)
    await transport.release()
    await first.value
    #expect(model.selectedPage?.id == 3)
    #expect(model.queuedPage == nil)
    #expect(!model.busy)
    let paths = await transport.paths
    #expect(paths.count == 2)
    #expect(!paths.contains { $0.hasSuffix("P2.md") })
}

@MainActor @Test
func supersededOpenReportsTheLaterPageAsOpened() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pages = (1...2).map { Page(id: $0, title: "Page \($0)", fileName: "P\($0).md", filePath: "", collectivePath: "Collectives/Team", parentId: 0) }
    let transport = HeldDownloadTransport()
    let (model, _) = navigationModel(transport: transport, pages: pages, root: root)
    let first = Task { await model.openPage(pages[0]) }
    await transport.waitForHeldRequest()
    #expect(await model.openPage(pages[1]))
    await transport.release()
    #expect(await first.value)
    #expect(model.selectedPage?.id == 2)
}

@MainActor @Test
func pageTappedDuringOtherWorkIsIgnored() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let page = Page(id: 1, title: "Page", fileName: "P.md", filePath: "", collectivePath: "Collectives/Team", parentId: 0)
    let (model, _) = navigationModel(transport: HeldDownloadTransport(), pages: [page], root: root)
    model.busy = true
    #expect(await model.openPage(page) == false)
    #expect(model.selectedPage == nil)
    #expect(model.queuedPage == nil)
}

private actor TrashTransport: HTTPTransport {
    private var trashed = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let root = #"{"id":1,"title":"Team","fileName":"Readme.md","filePath":"","parentId":0}"#
        let page = #"{"id":2,"title":"Note","fileName":"Note.md","filePath":"","parentId":1}"#
        let path = request.url!.path
        let payload: String
        switch request.httpMethod {
        case "DELETE": trashed = true; payload = "{}"
        case "PATCH": trashed = false; payload = "{\"page\":\(page)}"
        default:
            payload = path.hasSuffix("/trash")
                ? "{\"pages\":[\(trashed ? page : "")]}"
                : "{\"pages\":[\(root)\(trashed ? "" : "," + page)]}"
        }
        let body = "{\"ocs\":{\"meta\":{\"statuscode\":200},\"data\":\(payload)}}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Test
func undoAfterTrashRestoresThePage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let landing = Page(id: 1, title: "Team", fileName: "Readme.md", filePath: "", collectivePath: "Collectives/Team", parentId: 0)
    let note = Page(id: 2, title: "Note", fileName: "Note.md", filePath: "", collectivePath: "Collectives/Team", parentId: 1)
    let (model, account) = navigationModel(transport: TrashTransport(), pages: [landing, note], root: root)
    try await model.trashPage(pageID: 2,
        request: PageOrganizationRequest(accountID: account.id, collectiveID: 7, action: .trash(note)))
    #expect(model.pages.map(\.id) == [1])
    #expect(model.undoableTrash != nil)
    await model.undoTrash()
    #expect(model.pages.map(\.id).sorted() == [1, 2])
    #expect(model.undoableTrash == nil)
    #expect(model.message == "Page restored on the server.")
}

@MainActor @Test
func undoTrashExpiresWithItsMessage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let landing = Page(id: 1, title: "Team", fileName: "Readme.md", filePath: "", collectivePath: "Collectives/Team", parentId: 0)
    let note = Page(id: 2, title: "Note", fileName: "Note.md", filePath: "", collectivePath: "Collectives/Team", parentId: 1)
    let (model, account) = navigationModel(transport: TrashTransport(), pages: [landing, note], root: root)
    try await model.trashPage(pageID: 2,
        request: PageOrganizationRequest(accountID: account.id, collectiveID: 7, action: .trash(note)))
    model.message = ""
    #expect(model.undoableTrash == nil)
}

private actor FailingRestoreTransport: HTTPTransport {
    private var failRestore = true
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "PATCH" && failRestore {
            failRestore = false
            throw URLError(.notConnectedToInternet)
        }
        return try await trash.send(request)
    }
    private let trash = TrashTransport()
}

@MainActor @Test
func failedUndoTrashCanBeRetried() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let landing = Page(id: 1, title: "Team", fileName: "Readme.md", filePath: "", collectivePath: "Collectives/Team", parentId: 0)
    let note = Page(id: 2, title: "Note", fileName: "Note.md", filePath: "", collectivePath: "Collectives/Team", parentId: 1)
    let (model, account) = navigationModel(transport: FailingRestoreTransport(), pages: [landing, note], root: root)
    try await model.trashPage(pageID: 2,
        request: PageOrganizationRequest(accountID: account.id, collectiveID: 7, action: .trash(note)))
    await model.undoTrash()
    #expect(model.undoableTrash != nil)
    #expect(model.message.hasPrefix("Could not restore the page."))
    await model.undoTrash()
    #expect(model.pages.map(\.id).sorted() == [1, 2])
    #expect(model.undoableTrash == nil)
}

@MainActor @Test
func navigationTapDuringOtherWorkWaitsAndLatestTapWins() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, _) = navigationModel(transport: HeldDownloadTransport(), pages: [], root: root)
    model.busy = true
    let first = Task { await model.waitForNavigationTurn() }
    await Task.yield()
    let second = Task { await model.waitForNavigationTurn() }
    await Task.yield()
    model.busy = false
    #expect(await first.value == false)
    #expect(await second.value == true)
}

@MainActor @Test
func sidebarSelectsCollectiveBeforeRefreshingItsPages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = HeldDownloadTransport()
    let (model, account) = navigationModel(transport: transport, pages: [], root: root)
    model.snapshot.collectives.append(Collective(id: 8, name: "Other", canEdit: true))
    var selectedWhileRefreshing: Int?
    let open = Task {
        await model.openSidebar(accountID: account.id, collectiveID: 8) {
            selectedWhileRefreshing = model.selectedCollective
        }
    }
    await transport.waitForHeldRequest()
    #expect(selectedWhileRefreshing == 8)
    await transport.release()
    _ = await open.value
}
