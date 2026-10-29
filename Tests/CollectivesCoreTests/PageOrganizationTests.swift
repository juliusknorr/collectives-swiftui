import Foundation
import Testing
@testable import CollectivesCore

private func organizationPages(moved: Bool = false) -> [Page] {
    [Page(id: 9, title: "Team", fileName: "Readme.md", filePath: "", collectivePath: "Collectives/Team"),
     Page(id: 8, title: "Target", fileName: moved ? "Readme.md" : "Target.md", filePath: moved ? "Target" : "", collectivePath: "Collectives/Team", parentId: 9),
     Page(id: 1, title: "Folder", fileName: "Readme.md", filePath: moved ? "Target/Folder" : "Folder", collectivePath: "Collectives/Team", parentId: moved ? 8 : 9),
     Page(id: 2, title: "Child", fileName: "Child.md", filePath: moved ? "Target/Folder" : "Folder", collectivePath: "Collectives/Team", parentId: 1)]
}
private actor OrganizationStub: PageOrganizationAPI {
    enum Failure: Error { case offline }
    let mode: String
    private(set) var writes = 0
    private var moved = false
    private var trashed: Bool
    init(_ mode: String = "success", trashed: Bool = false) { self.mode = mode; self.trashed = trashed }
    func pages(collectiveID: Int) async throws -> [Page] {
        if writes > 0 && mode == "refresh" { throw Failure.offline }
        if mode == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
        let pages = organizationPages(moved: moved)
        return trashed ? pages.filter { ![1, 2].contains($0.id) } : pages
    }
    func trashedPages(collectiveID: Int) async throws -> [Page] {
        trashed ? Array(organizationPages().suffix(2)) : []
    }
    func movePage(collectiveID: Int, pageID: Int, parentID: Int) async throws -> Page {
        writes += 1
        if mode == "forbidden" { throw CollectivesError.http(403) }
        if mode == "failed" { throw Failure.offline }
        moved = true
        if mode == "lost" { throw Failure.offline }
        return organizationPages(moved: true)[2]
    }
    func trashPage(collectiveID: Int, pageID: Int) async throws {
        writes += 1
        if mode == "forbidden" { throw CollectivesError.http(403) }
        if mode == "failed" { throw Failure.offline }
        trashed = true
        if mode == "lost" { throw Failure.offline }
    }
    func restorePage(collectiveID: Int, pageID: Int) async throws -> Page {
        writes += 1
        if mode == "forbidden" { throw CollectivesError.http(403) }
        if mode == "failed" { throw Failure.offline }
        trashed = false
        if mode == "lost" { throw Failure.offline }
        return organizationPages()[2]
    }
}
private func organizationSnapshot(draft: Bool = false) -> AccountSnapshot {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 4, name: "Team")]
    snapshot.pages["4"] = organizationPages()
    for page in organizationPages() {
        snapshot.documents[String(page.id)] = CachedDocument(page: page, collectiveID: 4,
            markdown: "original \(page.id)", etag: "base \(page.id)", draft: draft && page.id == 2 ? "local child" : nil)
    }
    return snapshot
}

@Test(arguments: ["success", "lost", "refresh"])
func movePreservesSubtreeDraftAndBase(mode: String) async throws {
    let api = OrganizationStub(mode)
    let result = try await PageOrganizer.move(pageID: 1, parentID: 8, collectiveID: 4,
        snapshot: organizationSnapshot(draft: true), api: api)
    #expect(result.snapshot.documents["8"]?.page.fileName == "Readme.md")
    #expect(result.snapshot.documents["8"]?.page.filePath == "Target")
    #expect(result.snapshot.documents["8"]?.etag == "base 8")
    #expect(result.snapshot.documents["1"]?.page.parentId == 8)
    #expect(result.snapshot.documents["2"]?.page.filePath == "Target/Folder")
    #expect(result.snapshot.documents["2"]?.draft == "local child")
    #expect(result.snapshot.documents["2"]?.etag == "base 2")
    #expect(result.snapshot.documents["2"]?.markdown == "original 2")
    #expect(await api.writes == 1)
    #expect(result.warnings.isEmpty == (mode != "refresh"))
}

@Test(arguments: [1, 2, 77])
func moveRejectsSelfDescendantAndMissingParent(parentID: Int) async {
    let api = OrganizationStub()
    await #expect(throws: PageOrganizationError.self) {
        try await PageOrganizer.move(pageID: 1, parentID: parentID, collectiveID: 4,
            snapshot: organizationSnapshot(), api: api)
    }
    #expect(await api.writes == 0)
}

@Test func trashRejectsDraftsAndConflictsAnywhereInSubtree() async {
    for conflict in [false, true] {
        var snapshot = organizationSnapshot(draft: !conflict)
        if conflict { snapshot.documents["2"]?.conflict = RemoteDocument(markdown: "remote", etag: "remote") }
        let api = OrganizationStub()
        await #expect(throws: PageOrganizationError.self) {
            try await PageOrganizer.trash(pageID: 1, collectiveID: 4, snapshot: snapshot, api: api)
        }
        #expect(await api.writes == 0)
    }
}

@Test(arguments: ["success", "lost", "refresh"])
func trashRemovesCleanSubtreeButKeepsUnrelatedDraft(mode: String) async throws {
    let api = OrganizationStub(mode)
    var snapshot = organizationSnapshot()
    snapshot.documents["8"]?.draft = "other work"
    let result = try await PageOrganizer.trash(pageID: 1, collectiveID: 4, snapshot: snapshot, api: api)
    #expect(result.snapshot.documents["1"] == nil)
    #expect(result.snapshot.documents["2"] == nil)
    #expect(result.snapshot.documents["8"]?.draft == "other work")
    #expect(await api.writes == 1)
}

@Test(arguments: ["success", "lost", "refresh"])
func restoreReconcilesPagesAndPreservesExistingLocalWork(mode: String) async throws {
    let api = OrganizationStub(mode, trashed: true)
    var snapshot = organizationSnapshot()
    snapshot.documents["8"]?.draft = "other work"
    snapshot.replacePages(Array(organizationPages().prefix(2)), collectiveID: 4)
    let result = try await PageOrganizer.restore(pageID: 1, collectiveID: 4, snapshot: snapshot, api: api)
    #expect(result.snapshot.pages["4"]?.contains(where: { $0.id == 1 }) == true)
    #expect(result.snapshot.documents["8"]?.draft == "other work")
    #expect(await api.writes == 1)
    #expect(result.warnings.isEmpty == (mode != "refresh"))
}

@Test func organizationRejectsLandingPageAndReadOnlyBeforeWriting() async {
    let api = OrganizationStub()
    await #expect(throws: PageOrganizationError.self) {
        try await PageOrganizer.trash(pageID: 9, collectiveID: 4, snapshot: organizationSnapshot(), api: api)
    }
    await #expect(throws: PageOrganizationError.self) {
        try await PageOrganizer.move(pageID: 9, parentID: 8, collectiveID: 4, snapshot: organizationSnapshot(), api: api)
    }
    var readonly = organizationSnapshot()
    readonly.collectives = [Collective(id: 4, name: "Team", canEdit: false)]
    await #expect(throws: PageOrganizationError.self) {
        try await PageOrganizer.move(pageID: 1, parentID: 8, collectiveID: 4, snapshot: readonly, api: api)
    }
    await #expect(throws: PageOrganizationError.self) {
        try await PageOrganizer.restore(pageID: 1, collectiveID: 4, snapshot: readonly, api: api)
    }
    #expect(await api.writes == 0)
}

@Test(arguments: ["failed", "forbidden"])
func organizationNeverRetriesWrites(mode: String) async {
    for operation in 0...2 {
        let api = OrganizationStub(mode, trashed: operation == 2)
        await #expect(throws: (any Error).self) {
            if operation == 0 {
                _ = try await PageOrganizer.move(pageID: 1, parentID: 8, collectiveID: 4, snapshot: organizationSnapshot(), api: api)
            } else if operation == 1 {
                _ = try await PageOrganizer.trash(pageID: 1, collectiveID: 4, snapshot: organizationSnapshot(), api: api)
            } else {
                _ = try await PageOrganizer.restore(pageID: 1, collectiveID: 4, snapshot: organizationSnapshot(), api: api)
            }
        }
        #expect(await api.writes == 1)
    }
}

private actor OrganizationTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let page = organizationPages()[2]
        let data: Data
        if request.httpMethod == "GET" {
            struct Payload: Encodable { let pages: [Page] }
            let payload = try JSONEncoder().encode(Payload(pages: [page]))
            data = Data("{\"ocs\":{\"meta\":{\"statuscode\":100},\"data\":".utf8) + payload + Data("}}".utf8)
        } else if request.httpMethod == "DELETE" {
            struct Payload: Encodable { let page: Page }
            let payload = try JSONEncoder().encode(Payload(page: page))
            data = Data("{\"ocs\":{\"meta\":{\"statuscode\":100},\"data\":".utf8) + payload + Data("}}".utf8)
        } else {
            struct Payload: Encodable { let page: Page }
            let payload = try JSONEncoder().encode(Payload(page: page))
            data = Data("{\"ocs\":{\"meta\":{\"statuscode\":100},\"data\":".utf8) + payload + Data("}}".utf8)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func organizationClientUsesPinnedOCSRoutesAndParentPayload() async throws {
    let transport = OrganizationTransport()
    let client = CollectivesClient(account: Account(serverURL: URL(string: "https://cloud.example.test/nextcloud")!, userID: "alice"),
        credential: Credential(loginName: "alice", appPassword: "secret"), transport: transport)
    #expect(try await client.trashedPages(collectiveID: 4).count == 1)
    _ = try await client.movePage(collectiveID: 4, pageID: 1, parentID: 8)
    try await client.trashPage(collectiveID: 4, pageID: 1)
    _ = try await client.restorePage(collectiveID: 4, pageID: 1)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["GET", "PUT", "DELETE", "PATCH"])
    #expect(requests.map { $0.url!.path }.map { $0.replacingOccurrences(of: "/nextcloud/ocs/v2.php/apps/collectives/api/v1.0/collectives/4/pages", with: "") } == ["/trash", "/1", "/1", "/trash/1"])
    #expect(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Int] == ["parentId": 8])
}

@Test func organizationCancellationAfterPreflightDoesNotWrite() async {
    let api = OrganizationStub("cancel")
    let operation = Task {
        try await PageOrganizer.move(pageID: 1, parentID: 8, collectiveID: 4,
            snapshot: organizationSnapshot(), api: api)
    }
    do {
        _ = try await operation.value
        Issue.record("Cancelled preflight must not write")
    } catch is CancellationError { }
    catch { Issue.record("Unexpected cancellation error: \(error)") }
    #expect(await api.writes == 0)
}

@Test func organizationRequiresKnownWritableCollective() async {
    let api = OrganizationStub()
    await #expect(throws: PageOrganizationError.self) {
        try await PageOrganizer.move(pageID: 1, parentID: 8, collectiveID: 4,
            snapshot: AccountSnapshot(), api: api)
    }
    #expect(await api.writes == 0)
}
