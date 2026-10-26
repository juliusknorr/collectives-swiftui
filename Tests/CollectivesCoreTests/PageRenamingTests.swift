import Foundation
import Testing
@testable import CollectivesCore

private func folder(_ title: String = "Old", parentID: Int = 9) -> Page {
    Page(id: 1, title: title, fileName: "Readme.md", filePath: title,
         collectivePath: "Collectives/Team", parentId: parentID, emoji: "📚")
}
private func child(_ path: String = "Old/Nested") -> Page {
    Page(id: 2, title: "Child", fileName: "Child.md", filePath: path, collectivePath: "Collectives/Team", parentId: 1)
}
private actor RenameStub: PageRenamingAPI {
    enum Failure: Error { case offline }
    let failure: String?
    private(set) var lists = 0
    private(set) var writes = 0
    init(_ failure: String? = nil) { self.failure = failure }
    func pages(collectiveID: Int) async throws -> [Page] {
        lists += 1
        if failure == "offline" || (failure == "refresh" && lists > 1) { throw Failure.offline }
        if failure == "missing" { return [] }
        if failure == "landing" { return [folder(parentID: 0)] }
        if failure == "lost" && lists > 1 { return [folder("New"), child("New/Nested")] }
        if failure == "failed" || lists == 1 { return [folder(), child()] }
        return [folder("New"), child("New/Nested")]
    }
    func renamePage(collectiveID: Int, pageID: Int, title: String) async throws -> Page {
        writes += 1
        if failure == "lost" || failure == "failed" { throw Failure.offline }
        if failure == "forbidden" { throw CollectivesError.http(403) }
        return folder("New")
    }
}

@Test(arguments: ["success", "refresh", "lost"])
func renamePreservesDraftBasesAndUpdatesDescendantPaths(mode: String) async throws {
    var snapshot = AccountSnapshot()
    let conflict = RemoteDocument(markdown: "remote conflict", etag: "conflict revision")
    snapshot.documents["1"] = CachedDocument(page: folder(), collectiveID: 4, markdown: "# Old", etag: "base", draft: "local parent")
    snapshot.documents["2"] = CachedDocument(page: child(), collectiveID: 4, markdown: "child base", etag: "child revision", draft: "local child", conflict: conflict)
    snapshot.pages["8"] = [folder()]
    let api = RenameStub(mode)
    let result = try await PageRenamer.rename(title: " New ", pageID: 1, collectiveID: 4, snapshot: snapshot, api: api)
    #expect(result.page.title == "New")
    #expect(result.snapshot.documents["1"]?.page.filePath == "New")
    #expect(result.snapshot.documents["1"]?.draft == "local parent")
    #expect(result.snapshot.documents["1"]?.markdown == "# Old")
    #expect(result.snapshot.documents["1"]?.etag == "base")
    #expect(result.snapshot.documents["2"]?.page.filePath == "New/Nested")
    #expect(result.snapshot.documents["2"]?.draft == "local child")
    #expect(result.snapshot.documents["2"]?.etag == "child revision")
    #expect(result.snapshot.documents["2"]?.conflict == conflict)
    #expect(result.snapshot.pages["8"]?.first?.title == "Old")
    #expect(await api.writes == 1)
    #expect(result.warnings.isEmpty == (mode != "refresh"))
}

@Test(arguments: ["offline", "missing", "landing"])
func renamePreflightFailuresDoNotWrite(mode: String) async {
    let api = RenameStub(mode)
    await #expect(throws: (any Error).self) {
        try await PageRenamer.rename(title: "New", pageID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
    }
    #expect(await api.writes == 0)
}

@Test func renameDoesNotRepeatUnconfirmedWrites() async throws {
    let api = RenameStub("failed")
    do {
        _ = try await PageRenamer.rename(title: "New", pageID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
        Issue.record("Expected unconfirmed rename")
    } catch PageRenamingError.unconfirmed { }
    #expect(await api.writes == 1)
}

@Test func renameSkipsUnchangedTitle() async throws {
    let api = RenameStub()
    _ = try await PageRenamer.rename(title: " Old ", pageID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
    #expect(await api.writes == 0)
}

@Test func renameRetainsPermissionErrorWithoutRecoveryRequests() async {
    let api = RenameStub("forbidden")
    do {
        _ = try await PageRenamer.rename(title: "New", pageID: 1, collectiveID: 4, snapshot: AccountSnapshot(), api: api)
        Issue.record("Expected permission denial")
    } catch CollectivesError.http(403) { }
    catch { Issue.record("Unexpected error: \(error)") }
    #expect(await api.lists == 1)
}
