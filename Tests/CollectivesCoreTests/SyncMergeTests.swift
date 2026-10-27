import Testing
@testable import CollectivesCore

private func mergePage(_ id: Int = 1, title: String = "Page", parentID: Int = 0) -> Page {
    Page(id: id, title: title, fileName: "\(id).md", filePath: "", collectivePath: "Team", parentId: parentID)
}

private func mergeSnapshot(draft: String? = nil, conflict: RemoteDocument? = nil) -> AccountSnapshot {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 1, name: "Team")]
    snapshot.pages["1"] = [mergePage()]
    snapshot.documents["1"] = CachedDocument(page: mergePage(), collectiveID: 1,
        markdown: "base", etag: "base-revision", draft: draft, conflict: conflict)
    return snapshot
}

@Test func syncMergeAdoptsUploadedRevisionAndKeepsTypingDuringUpload() {
    let base = mergeSnapshot(draft: "uploaded draft")
    var local = base
    local.documents["1"]?.draft = "newer typing"
    var remote = base
    remote.documents["1"]?.markdown = "uploaded draft"
    remote.documents["1"]?.etag = "uploaded-revision"
    remote.documents["1"]?.draft = nil

    let merged = local.mergingSync(remote, startedFrom: base)
    #expect(merged.documents["1"]?.markdown == "uploaded draft")
    #expect(merged.documents["1"]?.etag == "uploaded-revision")
    #expect(merged.documents["1"]?.draft == "newer typing")
}

@Test func syncMergeClearsDraftMatchingUploadedTextAndIsStableAcrossCheckpoints() {
    let base = mergeSnapshot(draft: "uploaded draft")
    var remote = base
    remote.documents["1"]?.markdown = "uploaded draft"
    remote.documents["1"]?.etag = "uploaded-revision"
    remote.documents["1"]?.draft = nil
    let first = base.mergingSync(remote, startedFrom: base)
    let second = first.mergingSync(remote, startedFrom: base)
    #expect(second.documents["1"]?.draft == nil)
    #expect(second.documents["1"]?.etag == "uploaded-revision")
}

@Test func syncMergeKeepsEditRevertedToOriginalTextWhileUploadRuns() {
    let base = mergeSnapshot(draft: "uploaded draft")
    var local = base
    local.documents["1"]?.draft = nil
    var remote = base
    remote.documents["1"]?.markdown = "uploaded draft"
    remote.documents["1"]?.etag = "uploaded-revision"
    remote.documents["1"]?.draft = nil
    let merged = local.mergingSync(remote, startedFrom: base)
    #expect(merged.documents["1"]?.draft == "base")
    #expect(merged.documents["1"]?.etag == "uploaded-revision")
}

@Test func syncMergeRetainsConflictWithLatestTyping() {
    let base = mergeSnapshot(draft: "initial draft")
    var local = base
    local.documents["1"]?.draft = "latest draft"
    var remote = base
    let conflict = RemoteDocument(markdown: "server changes", etag: "server-revision")
    remote.documents["1"]?.conflict = conflict
    let merged = local.mergingSync(remote, startedFrom: base)
    #expect(merged.documents["1"]?.draft == "latest draft")
    #expect(merged.documents["1"]?.conflict == conflict)
}

@Test func syncMergeDetectsServerChangesDownloadedWhileTypingInCleanPage() {
    let base = mergeSnapshot()
    var local = base
    local.documents["1"]?.draft = "typed during download"
    var remote = base
    remote.documents["1"]?.markdown = "competing server edit"
    remote.documents["1"]?.etag = "server-revision"
    let merged = local.mergingSync(remote, startedFrom: base)
    #expect(merged.documents["1"]?.markdown == "base")
    #expect(merged.documents["1"]?.etag == "base-revision")
    #expect(merged.documents["1"]?.draft == "typed during download")
    #expect(merged.documents["1"]?.conflict == RemoteDocument(markdown: "competing server edit", etag: "server-revision"))
}

@Test func syncMergeAdoptsNewRevisionWithUnchangedContentWhileTypingInCleanPage() {
    let base = mergeSnapshot()
    var local = base
    local.documents["1"]?.draft = "typed during download"
    var remote = base
    remote.documents["1"]?.etag = "new-revision-same-content"
    let merged = local.mergingSync(remote, startedFrom: base)
    #expect(merged.documents["1"]?.markdown == "base")
    #expect(merged.documents["1"]?.etag == "new-revision-same-content")
    #expect(merged.documents["1"]?.draft == "typed during download")
    #expect(merged.documents["1"]?.conflict == nil)
}

@Test func syncMergeAcceptsRemoteContentForPageDownloadedDuringSync() {
    var base = mergeSnapshot()
    base.documents = [:]
    let local = mergeSnapshot()
    var remote = mergeSnapshot()
    remote.documents["1"]?.markdown = "newer server content"
    remote.documents["1"]?.etag = "newer-server-etag"
    let merged = local.mergingSync(remote, startedFrom: base)
    #expect(merged.documents["1"]?.markdown == "newer server content")
    #expect(merged.documents["1"]?.etag == "newer-server-etag")
    #expect(merged.documents["1"]?.draft == nil)
    #expect(merged.documents["1"]?.conflict == nil)
}

@Test func syncMergeDetectsConflictForPageDownloadedAndEditedDuringSync() {
    var base = mergeSnapshot()
    base.documents = [:]
    let local = mergeSnapshot(draft: "edited after download")
    var remote = mergeSnapshot()
    remote.documents["1"]?.markdown = "newer server content"
    remote.documents["1"]?.etag = "newer-server-etag"
    let merged = local.mergingSync(remote, startedFrom: base)
    #expect(merged.documents["1"]?.markdown == "base")
    #expect(merged.documents["1"]?.etag == "base-revision")
    #expect(merged.documents["1"]?.draft == "edited after download")
    #expect(merged.documents["1"]?.conflict == RemoteDocument(markdown: "newer server content", etag: "newer-server-etag"))
}

@Test func syncMergePreservesConflictResolutionDuringSync() {
    let conflict = RemoteDocument(markdown: "server changes", etag: "server-revision")
    let base = mergeSnapshot(draft: "my changes", conflict: conflict)
    var local = base
    local.documents["1"]?.markdown = conflict.markdown
    local.documents["1"]?.etag = conflict.etag
    local.documents["1"]?.draft = nil
    local.documents["1"]?.conflict = nil
    let merged = local.mergingSync(base, startedFrom: base)
    #expect(merged.documents["1"]?.markdown == "server changes")
    #expect(merged.documents["1"]?.etag == "server-revision")
    #expect(merged.documents["1"]?.draft == nil)
    #expect(merged.documents["1"]?.conflict == nil)
}

@Test func syncMergeCombinesConcurrentRenameAndCreationWithRemoteChanges() {
    let base = mergeSnapshot()
    var local = base
    local.collectives = [Collective(id: 1, name: "Renamed team")]
    local.pages["1"] = [mergePage(title: "Local rename"), mergePage(2)]
    local.documents["1"]?.page = mergePage(title: "Local rename")
    local.documents["2"] = CachedDocument(page: mergePage(2), collectiveID: 1, markdown: "created", etag: "created-revision")
    var remote = base
    remote.pages["1"] = [mergePage(title: "Old title"), mergePage(3)]
    remote.documents["1"]?.markdown = "fresh server content"
    remote.documents["1"]?.etag = "fresh-revision"
    let merged = local.mergingSync(remote, startedFrom: base)
    #expect(merged.collectives.first?.name == "Renamed team")
    #expect(merged.pages["1"]?.map(\.id) == [1, 3, 2])
    #expect(merged.documents["1"]?.page.title == "Local rename")
    #expect(merged.documents["1"]?.markdown == "fresh server content")
    #expect(merged.documents["2"]?.markdown == "created")
}

@Test func syncMergeRetainsConcurrentWorkAndParentsAfterRemoteDeletion() {
    var base = mergeSnapshot()
    base.pages["1"] = [mergePage(10), mergePage(parentID: 10)]
    base.documents["1"]?.page = mergePage(parentID: 10)
    var local = base
    local.documents["1"]?.draft = "new work"
    let merged = local.mergingSync(AccountSnapshot(), startedFrom: base)
    #expect(merged.collectives == base.collectives)
    #expect(Set(merged.pages["1"]?.map(\.id) ?? []) == [1, 10])
    #expect(merged.documents["1"]?.draft == "new work")
    let unchanged = base.mergingSync(AccountSnapshot(), startedFrom: base)
    #expect(unchanged.collectives.isEmpty)
    #expect(unchanged.pages.isEmpty)
    #expect(unchanged.documents.isEmpty)
}

@Test func syncMergeAdvancesBaselineBetweenCheckpointsWithoutLosingConcurrentDraft() {
    let base = mergeSnapshot()
    var firstCheckpoint = base
    firstCheckpoint.documents["1"]?.markdown = "downloaded revision"
    firstCheckpoint.documents["1"]?.etag = "downloaded-etag"
    var local = base.mergingSync(firstCheckpoint, startedFrom: base)
    local.documents["1"]?.draft = "typing after download"
    var nextCheckpoint = firstCheckpoint
    nextCheckpoint.documents["1"]?.markdown = "new server revision"
    nextCheckpoint.documents["1"]?.etag = "new-server-etag"
    let merged = local.mergingSync(nextCheckpoint, startedFrom: firstCheckpoint)
    #expect(merged.documents["1"]?.markdown == "downloaded revision")
    #expect(merged.documents["1"]?.etag == "downloaded-etag")
    #expect(merged.documents["1"]?.draft == "typing after download")
    #expect(merged.documents["1"]?.conflict == RemoteDocument(markdown: "new server revision", etag: "new-server-etag"))
    let unchanged = firstCheckpoint.mergingSync(nextCheckpoint, startedFrom: firstCheckpoint)
    #expect(unchanged.documents["1"]?.draft == nil)
    #expect(unchanged.documents["1"]?.markdown == "new server revision")
}
