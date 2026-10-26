import Foundation
import Testing
@testable import CollectivesCore

private let parent = Page(id: 1, title: "Parent", fileName: "Parent.md", filePath: "", collectivePath: "Collectives/Team", parentId: 9)
private let movedParent = Page(id: 1, title: "Parent", fileName: "Readme.md", filePath: "Parent", collectivePath: "Collectives/Team", parentId: 9)
private let child = Page(id: 2, title: "New 🌱", fileName: "New 🌱.md", filePath: "Parent", collectivePath: "Collectives/Team", parentId: 1)

private actor CreationStub: PageCreationAPI {
    enum Failure: Error { case offline }
    let failure: String?
    private(set) var listCalls = 0
    private(set) var createCalls = 0
    private(set) var downloadCalls = 0
    private(set) var requestedTitle: String?
    init(failure: String? = nil) { self.failure = failure }
    func pages(collectiveID: Int) async throws -> [Page] {
        listCalls += 1
        if failure == "preflight" || (failure == "refresh" && listCalls == 2) { throw Failure.offline }
        if failure == "parent" { return [] }
        return listCalls == 1 ? [parent] : [movedParent, child]
    }
    func createPage(collectiveID: Int, parentID: Int, title: String) async throws -> Page {
        createCalls += 1; requestedTitle = title
        if failure == "post" { throw Failure.offline }
        if failure == "forbidden" { throw CollectivesError.http(403) }
        return child
    }
    func download(page: Page) async throws -> RemoteDocument {
        downloadCalls += 1
        if failure == "download" { throw Failure.offline }
        return RemoteDocument(markdown: "# New 🌱\n", etag: "new revision")
    }
}

@Test func creationRefreshesParentPathsWithoutChangingDraftBases() async throws {
    var snapshot = AccountSnapshot()
    let conflict = RemoteDocument(markdown: "competing", etag: "other")
    snapshot.documents["1"] = CachedDocument(page: parent, collectiveID: 4, markdown: "base", etag: "base revision", draft: "local draft", conflict: conflict)
    snapshot.documents["99"] = CachedDocument(page: parent, collectiveID: 8, markdown: "other account collection", etag: "other revision")
    snapshot.pages["8"] = [parent]
    let api = CreationStub()
    let result = try await PageCreator.create(title: " New 🌱 ", parentID: 1, collectiveID: 4, snapshot: snapshot, api: api)
    #expect(result.page == child)
    #expect(result.snapshot.documents["1"]?.page == movedParent)
    #expect(result.snapshot.documents["1"]?.draft == "local draft")
    #expect(result.snapshot.documents["1"]?.markdown == "base")
    #expect(result.snapshot.documents["1"]?.etag == "base revision")
    #expect(result.snapshot.documents["1"]?.conflict == conflict)
    #expect(result.snapshot.documents["99"]?.markdown == snapshot.documents["99"]?.markdown)
    #expect(result.snapshot.documents["99"]?.etag == "other revision")
    #expect(result.snapshot.pages["8"] == [parent])
    #expect(result.snapshot.documents["2"]?.markdown == "# New 🌱\n")
    #expect(result.warnings.isEmpty)
    #expect(await api.requestedTitle == "New 🌱")
    #expect(await api.createCalls == 1)
}

@Test(arguments: ["", "  ", ".", "..", "one/two", "one\\two", "one\ntwo", "one\u{0}two"])
func creationRejectsInvalidTitlesBeforeNetworking(title: String) async {
    let api = CreationStub()
    await #expect(throws: PageCreationError.self) {
        try await PageCreator.create(title: title, parentID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
    }
    #expect(await api.listCalls == 0)
    #expect(await api.createCalls == 0)
}

@Test(arguments: ["preflight", "parent"])
func creationRequiresAnAvailableParentBeforePosting(failure: String) async {
    let api = CreationStub(failure: failure)
    await #expect(throws: (any Error).self) {
        try await PageCreator.create(title: "New", parentID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
    }
    #expect(await api.createCalls == 0)
}

@Test func creationDoesNotRetryAnAmbiguousPost() async throws {
    let api = CreationStub(failure: "post")
    do {
        _ = try await PageCreator.create(title: "New", parentID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
        Issue.record("Expected an unconfirmed creation")
    } catch PageCreationError.unconfirmed { }
    #expect(await api.createCalls == 1)
    #expect(await api.listCalls == 1)
    #expect(await api.downloadCalls == 0)
}

@Test func creationPreservesDefinitivePermissionErrors() async {
    let api = CreationStub(failure: "forbidden")
    do {
        _ = try await PageCreator.create(title: "New", parentID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
        Issue.record("Expected permission denial")
    } catch CollectivesError.http(403) { }
    catch { Issue.record("Unexpected error: \(error)") }
    #expect(await api.createCalls == 1)
}

@Test(arguments: ["refresh", "download"])
func creationReportsSuccessWhenFollowupRequestsFail(failure: String) async throws {
    let api = CreationStub(failure: failure)
    let result = try await PageCreator.create(title: "New", parentID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
    #expect(result.page.id == 2)
    #expect(result.snapshot.pages["4"]?.contains(where: { $0.id == 2 }) == true)
    #expect(!result.warnings.isEmpty)
    #expect(await api.createCalls == 1)
    #expect((result.snapshot.documents["2"] == nil) == (failure == "download"))
}

@Test func creationNeverReplacesAnExistingDraftIfServerReturnsAnExistingID() async throws {
    var snapshot = AccountSnapshot()
    snapshot.documents["2"] = CachedDocument(page: child, collectiveID: 4, markdown: "base", etag: "base", draft: "retained")
    let api = CreationStub()
    let result = try await PageCreator.create(title: "New", parentID: 1, collectiveID: 4, snapshot: snapshot, api: api)
    #expect(result.snapshot.documents["2"]?.draft == "retained")
    #expect(await api.downloadCalls == 0)
}
