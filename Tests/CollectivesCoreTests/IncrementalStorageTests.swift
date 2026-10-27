import Foundation
import Testing
@testable import CollectivesCore

private func storagePage(_ id: Int) -> Page {
    Page(id: id, title: "Page \(id)", fileName: "Page \(id).md", filePath: "", collectivePath: "Collectives/Test")
}

private func storageSnapshot() -> AccountSnapshot {
    var snapshot = AccountSnapshot()
    snapshot.collectives = [Collective(id: 7, name: "Test")]
    snapshot.pages["7"] = [storagePage(1), storagePage(2)]
    snapshot.documents["1"] = CachedDocument(page: storagePage(1), collectiveID: 7,
        markdown: "First base", etag: "first-base", draft: "First draft",
        conflict: RemoteDocument(markdown: "First remote", etag: "first-remote"))
    snapshot.documents["2"] = CachedDocument(page: storagePage(2), collectiveID: 7,
        markdown: "Second base", etag: "second-base")
    return snapshot
}

private func storageRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func accountDirectory(_ root: URL, _ accountID: UUID) -> URL {
    root.appendingPathComponent(accountID.uuidString, isDirectory: true)
}

private func storageManifest(_ root: URL, _ accountID: UUID) throws -> [String: Any] {
    let data = try Data(contentsOf: accountDirectory(root, accountID).appendingPathComponent("manifest.json"))
    let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(manifest["version"] as? Int == 1)
    return manifest
}

private func documentFiles(_ root: URL, _ accountID: UUID) throws -> [String: String] {
    try #require(storageManifest(root, accountID)["documentFiles"] as? [String: String])
}

@Test func legacySnapshotMigrationPreservesDraftBaseAndConflictTogether() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let legacyURL = root.appendingPathComponent(accountID.uuidString + ".json")
    let original = storageSnapshot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacyData = try JSONEncoder().encode(original)
    try legacyData.write(to: legacyURL)

    let migrated = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(migrated.collectives == original.collectives)
    #expect(migrated.pages == original.pages)
    #expect(migrated.documents == original.documents)
    #expect(try Data(contentsOf: legacyURL) == legacyData)
    #expect(try documentFiles(root, accountID).count == 2)
    let restarted = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(restarted.documents == original.documents)
}

@Test func interruptedDocumentWriteLeavesCommittedSnapshotReadableOnRestart() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let original = storageSnapshot()
    try await LocalStore(root: root).saveSnapshot(original, accountID: accountID)
    let directory = accountDirectory(root, accountID).appendingPathComponent("documents", isDirectory: true)
    let uncommitted = directory.appendingPathComponent(UUID().uuidString + ".json")
    var abandoned = try #require(original.documents["1"])
    abandoned.draft = "Uncommitted replacement"
    try JSONEncoder().encode(abandoned).write(to: uncommitted)

    let restarted = LocalStore(root: root)
    let recovered = try await restarted.snapshot(accountID: accountID)
    #expect(recovered.documents == original.documents)
    #expect(recovered.pages == original.pages)
    var next = try #require(recovered.documents["2"])
    next.draft = "A later committed edit"
    try await restarted.saveDocument(next, accountID: accountID)
    let saved = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(saved.documents["1"] == original.documents["1"])
    #expect(saved.documents["2"] == next)
}

@Test func singleDocumentSavePreservesOtherDocumentsAndLatestMetadata() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let store = LocalStore(root: root)
    var latest = storageSnapshot()
    try await store.saveSnapshot(latest, accountID: accountID)
    var edited = try #require(latest.documents["1"])
    edited.draft = "New editor draft"
    latest.collectives = [Collective(id: 7, name: "Renamed collective")]
    latest.pages["7"]?.append(storagePage(3))
    latest.documents["2"]?.markdown = "New sync content"
    latest.documents["2"]?.etag = "new-sync-revision"
    try await store.saveSnapshot(latest, accountID: accountID)
    let before = try documentFiles(root, accountID)
    let metadataBefore = try #require(storageManifest(root, accountID)["metadataFile"] as? String)
    let otherFile = accountDirectory(root, accountID).appendingPathComponent("documents").appendingPathComponent(try #require(before["2"]))
    let otherData = try Data(contentsOf: otherFile)
    let sentinel = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: otherFile.path)

    try await store.saveDocument(edited, accountID: accountID)
    let after = try documentFiles(root, accountID)
    #expect(try storageManifest(root, accountID)["metadataFile"] as? String == metadataBefore)
    #expect(after["1"] != before["1"])
    #expect(after["2"] == before["2"])
    #expect(try Data(contentsOf: otherFile) == otherData)
    #expect(try FileManager.default.attributesOfItem(atPath: otherFile.path)[.modificationDate] as? Date == sentinel)
    let loaded = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(loaded.collectives == latest.collectives)
    #expect(loaded.pages == latest.pages)
    #expect(loaded.documents["1"] == edited)
    #expect(loaded.documents["2"] == latest.documents["2"])
}

@Test func failedDocumentWriteKeepsPreviousManifestAndDraftOnRestart() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let original = storageSnapshot()
    let store = LocalStore(root: root)
    try await store.saveSnapshot(original, accountID: accountID)
    let directory = accountDirectory(root, accountID)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: manifestURL)
    let documents = directory.appendingPathComponent("documents", isDirectory: true)
    let retained = directory.appendingPathComponent("retained-documents", isDirectory: true)
    try FileManager.default.moveItem(at: documents, to: retained)
    try Data("Directory temporarily unavailable".utf8).write(to: documents)
    var changed = try #require(original.documents["1"])
    changed.draft = "This save must fail"
    await #expect(throws: (any Error).self) {
        try await store.saveDocument(changed, accountID: accountID)
    }
    #expect(try Data(contentsOf: manifestURL) == before)
    try FileManager.default.removeItem(at: documents)
    try FileManager.default.moveItem(at: retained, to: documents)
    let restarted = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(restarted.documents == original.documents)
}

@Test func unsupportedManifestVersionIsRejectedWithLegacyBackupPresent() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let store = LocalStore(root: root)
    try await store.saveSnapshot(storageSnapshot(), accountID: accountID)
    let legacy = root.appendingPathComponent(accountID.uuidString + ".json")
    try JSONEncoder().encode(storageSnapshot()).write(to: legacy)
    var manifest = try storageManifest(root, accountID)
    manifest["version"] = 999
    let manifestURL = accountDirectory(root, accountID).appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    await #expect(throws: (any Error).self) {
        _ = try await LocalStore(root: root).snapshot(accountID: accountID)
    }
    #expect(FileManager.default.fileExists(atPath: legacy.path))
}

@Test func metadataOnlySnapshotSaveKeepsDocumentFiles() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let store = LocalStore(root: root)
    var snapshot = storageSnapshot()
    try await store.saveSnapshot(snapshot, accountID: accountID)
    let before = try documentFiles(root, accountID)
    snapshot.collectives = [Collective(id: 7, name: "Renamed")]
    snapshot.pages["7"] = [storagePage(2)]
    try await store.saveSnapshot(snapshot, accountID: accountID)
    #expect(try documentFiles(root, accountID) == before)
    let loaded = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(loaded.collectives == snapshot.collectives)
    #expect(loaded.pages == snapshot.pages)
    #expect(loaded.documents == snapshot.documents)
}

@Test(arguments: [false, true]) func corruptActiveStorageNeverFallsBackToLegacySnapshot(corruptManifest: Bool) async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacy = root.appendingPathComponent(accountID.uuidString + ".json")
    try JSONEncoder().encode(storageSnapshot()).write(to: legacy)
    let store = LocalStore(root: root)
    _ = try await store.snapshot(accountID: accountID)
    let directory = accountDirectory(root, accountID)
    let target: URL
    if corruptManifest {
        target = directory.appendingPathComponent("manifest.json")
    } else {
        let files = try documentFiles(root, accountID)
        target = directory.appendingPathComponent("documents").appendingPathComponent(try #require(files["1"]))
    }
    try Data("{truncated".utf8).write(to: target)
    await #expect(throws: (any Error).self) {
        _ = try await LocalStore(root: root).snapshot(accountID: accountID)
    }
    #expect(FileManager.default.fileExists(atPath: legacy.path))
}

@Test func snapshotDeletionPersistsWhenAnotherDocumentIsEdited() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let store = LocalStore(root: root)
    var snapshot = storageSnapshot()
    try await store.saveSnapshot(snapshot, accountID: accountID)
    snapshot.documents.removeValue(forKey: "2")
    snapshot.pages["7"] = [storagePage(1)]
    try await store.saveSnapshot(snapshot, accountID: accountID)
    var first = try #require(snapshot.documents["1"])
    first.draft = "Edited after deletion"
    try await store.saveDocument(first, accountID: accountID)
    let restarted = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(restarted.documents.count == 1)
    #expect(restarted.documents["1"] == first)
    #expect(restarted.documents["2"] == nil)
    #expect(restarted.pages["7"] == [storagePage(1)])
    #expect(try documentFiles(root, accountID).keys.sorted() == ["1"])
}

@Test func removingMigratedAccountRemovesBackupAndIncrementalStorage() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let account = Account(serverURL: URL(string: "https://cloud.example.test")!, userID: "alice")
    let store = LocalStore(root: root)
    try await store.saveAccounts([account])
    var snapshot = storageSnapshot()
    snapshot.documents["1"]?.draft = nil
    snapshot.documents["1"]?.conflict = nil
    let legacy = root.appendingPathComponent(account.id.uuidString + ".json")
    try JSONEncoder().encode(snapshot).write(to: legacy)
    _ = try await store.snapshot(accountID: account.id)
    #expect(FileManager.default.fileExists(atPath: legacy.path))
    #expect(FileManager.default.fileExists(atPath: accountDirectory(root, account.id).path))

    try await store.removeAccount(accountID: account.id) { #expect($0 == account.id) }
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(!FileManager.default.fileExists(atPath: accountDirectory(root, account.id).path))
    #expect(try await store.accounts().isEmpty)
    #expect(try await LocalStore(root: root).snapshot(accountID: account.id).documents.isEmpty)
}

@Test func interruptedMigrationRetainsLegacySnapshotAndCanRetry() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let original = storageSnapshot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacyURL = root.appendingPathComponent(accountID.uuidString + ".json")
    let legacyData = try JSONEncoder().encode(original)
    try legacyData.write(to: legacyURL)
    let directory = accountDirectory(root, accountID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let obstruction = directory.appendingPathComponent("documents")
    try Data("Blocked migration".utf8).write(to: obstruction)
    await #expect(throws: (any Error).self) {
        _ = try await LocalStore(root: root).snapshot(accountID: accountID)
    }
    #expect(try Data(contentsOf: legacyURL) == legacyData)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    try FileManager.default.removeItem(at: obstruction)
    let recovered = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(recovered.documents == original.documents)
    #expect(recovered.pages == original.pages)
}

@Test func syncCheckpointWritesOnlyChangedDocumentsAndNoOpKeepsManifest() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let store = LocalStore(root: root)
    var snapshot = storageSnapshot()
    try await store.saveSnapshot(snapshot, accountID: accountID)
    let before = try documentFiles(root, accountID)
    snapshot.documents["2"]?.markdown = "Downloaded checkpoint"
    snapshot.documents["2"]?.etag = "checkpoint-etag"
    try await store.saveSnapshot(snapshot, accountID: accountID)
    let after = try documentFiles(root, accountID)
    #expect(after["1"] == before["1"])
    #expect(after["2"] != before["2"])
    let manifestURL = accountDirectory(root, accountID).appendingPathComponent("manifest.json")
    let sentinel = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: manifestURL.path)
    try await store.saveSnapshot(snapshot, accountID: accountID)
    #expect(try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date == sentinel)
    let restarted = try await LocalStore(root: root).snapshot(accountID: accountID)
    #expect(restarted.documents == snapshot.documents)
}

@Test func failedManifestCommitLeavesPreviousDraftAndCanRetry() async throws {
    let root = storageRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let original = storageSnapshot()
    let store = LocalStore(root: root)
    try await store.saveSnapshot(original, accountID: accountID)
    let manifestURL = accountDirectory(root, accountID).appendingPathComponent("manifest.json")
    let retained = accountDirectory(root, accountID).appendingPathComponent("retained-manifest.json")
    try FileManager.default.moveItem(at: manifestURL, to: retained)
    try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
    var edited = try #require(original.documents["1"])
    edited.draft = "Edit after manifest failure"
    await #expect(throws: (any Error).self) {
        try await store.saveDocument(edited, accountID: accountID)
    }
    try FileManager.default.removeItem(at: manifestURL)
    try FileManager.default.moveItem(at: retained, to: manifestURL)
    let restarted = LocalStore(root: root)
    #expect(try await restarted.snapshot(accountID: accountID).documents == original.documents)
    try await restarted.saveDocument(edited, accountID: accountID)
    #expect(try await LocalStore(root: root).snapshot(accountID: accountID).documents["1"] == edited)
}
