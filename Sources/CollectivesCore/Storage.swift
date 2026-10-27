import Foundation
import Security

public struct Credential: Codable, Sendable {
    public let loginName: String
    public let appPassword: String
    public init(loginName: String, appPassword: String) { self.loginName = loginName; self.appPassword = appPassword }
}
public struct KeychainCredentialStore: Sendable {
    public let service: String
    public init(service: String = "com.nextcloud.collectives.credentials") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    public func save(_ credential: Credential, accountID: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query(accountID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(accountID)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw CollectivesError.credential(result) }
        } else if status != errSecSuccess { throw CollectivesError.credential(status) }
    }
    public func credential(accountID: UUID) throws -> Credential? {
        var item = query(accountID)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CollectivesError.credential(status) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }
    public func remove(accountID: UUID) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CollectivesError.credential(status) }
    }
}

/// Immutable document files keep a draft and its base revision together. The atomic
/// manifest is the commit point, so interrupted writes cannot expose half a save.
public actor LocalStore {
    public let root: URL
    private struct Metadata: Codable, Equatable {
        var collectives: [Collective]
        var pages: [String: [Page]]
        init(_ snapshot: AccountSnapshot) {
            collectives = snapshot.collectives
            pages = snapshot.pages
        }
    }
    private struct Manifest: Codable {
        var version = 1
        var metadataFile: String
        var documentFiles: [String: String]
    }
    private struct StoredAccount {
        var snapshot: AccountSnapshot
        var manifest: Manifest
    }
    // AppModel owns one store for this root; all commits pass through this actor.
    private var loaded: [UUID: StoredAccount] = [:]

    public init(root: URL) { self.root = root }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public func accounts() throws -> [Account] {
        let url = root.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try read([Account].self, at: url)
    }
    public func saveAccounts(_ accounts: [Account]) throws {
        try write(accounts, at: root.appendingPathComponent("accounts.json"))
    }
    public func snapshot(accountID: UUID) throws -> AccountSnapshot {
        if let stored = loaded[accountID] { return stored.snapshot }
        let manifestURL = directory(accountID).appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest = try read(Manifest.self, at: manifestURL)
            guard manifest.version == 1 else { throw LocalStorageError.unsupportedVersion(manifest.version) }
            let metadata = try read(Metadata.self, at: assetURL(manifest.metadataFile, folder: "metadata", accountID: accountID))
            var snapshot = AccountSnapshot()
            snapshot.collectives = metadata.collectives
            snapshot.pages = metadata.pages
            for (key, file) in manifest.documentFiles {
                let document = try read(CachedDocument.self, at: assetURL(file, folder: "documents", accountID: accountID))
                guard key == String(document.page.id) else { throw LocalStorageError.invalidDocument }
                snapshot.documents[key] = document
            }
            loaded[accountID] = StoredAccount(snapshot: snapshot, manifest: manifest)
            removeOrphans(accountID: accountID, manifest: manifest)
            return snapshot
        }
        let legacyURL = snapshotURL(accountID)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return AccountSnapshot() }
        let legacy = try read(AccountSnapshot.self, at: legacyURL)
        // Keep the original snapshot as recovery data, including after migration.
        try commit(legacy, accountID: accountID, previous: nil)
        return legacy
    }
    public func saveSnapshot(_ snapshot: AccountSnapshot, accountID: UUID) throws {
        _ = try self.snapshot(accountID: accountID)
        try commit(snapshot, accountID: accountID, previous: loaded[accountID])
    }
    public func saveDocument(_ document: CachedDocument, accountID: UUID) throws {
        _ = try snapshot(accountID: accountID)
        guard var stored = loaded[accountID] else {
            var snapshot = AccountSnapshot()
            snapshot.documents[String(document.page.id)] = document
            try commit(snapshot, accountID: accountID, previous: nil)
            return
        }
        let key = String(document.page.id)
        guard stored.snapshot.documents[key] != document else { return }
        let oldFile = stored.manifest.documentFiles[key]
        let file = UUID().uuidString + ".json"
        try write(document, at: assetURL(file, folder: "documents", accountID: accountID))
        stored.manifest.documentFiles[key] = file
        try write(stored.manifest, at: directory(accountID).appendingPathComponent("manifest.json"))
        stored.snapshot.documents[key] = document
        loaded[accountID] = stored
        if let oldFile { removeAsset(oldFile, folder: "documents", accountID: accountID) }
    }
    private func commit(_ snapshot: AccountSnapshot, accountID: UUID, previous: StoredAccount?) throws {
        var manifest = previous?.manifest ?? Manifest(metadataFile: "", documentFiles: [:])
        if previous.map({ Metadata($0.snapshot) }) != Metadata(snapshot) {
            manifest.metadataFile = UUID().uuidString + ".json"
            try write(Metadata(snapshot), at: assetURL(manifest.metadataFile, folder: "metadata", accountID: accountID))
        }
        for (key, document) in snapshot.documents {
            guard key == String(document.page.id) else { throw LocalStorageError.invalidDocument }
            if previous?.snapshot.documents[key] != document {
                let file = UUID().uuidString + ".json"
                try write(document, at: assetURL(file, folder: "documents", accountID: accountID))
                manifest.documentFiles[key] = file
            }
        }
        manifest.documentFiles = manifest.documentFiles.filter { snapshot.documents[$0.key] != nil }
        if let previous, manifest.metadataFile == previous.manifest.metadataFile,
           manifest.documentFiles == previous.manifest.documentFiles { return }
        try write(manifest, at: directory(accountID).appendingPathComponent("manifest.json"))
        loaded[accountID] = StoredAccount(snapshot: snapshot, manifest: manifest)
        if let previous {
            if previous.manifest.metadataFile != manifest.metadataFile {
                removeAsset(previous.manifest.metadataFile, folder: "metadata", accountID: accountID)
            }
            for (key, file) in previous.manifest.documentFiles where file != manifest.documentFiles[key] {
                removeAsset(file, folder: "documents", accountID: accountID)
            }
        } else { removeOrphans(accountID: accountID, manifest: manifest) }
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func assetURL(_ file: String, folder: String, accountID: UUID) throws -> URL {
        guard file.hasSuffix(".json"), UUID(uuidString: String(file.dropLast(5))) != nil else {
            throw LocalStorageError.invalidDocument
        }
        return directory(accountID).appendingPathComponent(folder, isDirectory: true).appendingPathComponent(file)
    }
    private func removeAsset(_ file: String, folder: String, accountID: UUID) {
        if let url = try? assetURL(file, folder: folder, accountID: accountID) { try? FileManager.default.removeItem(at: url) }
    }
    private func removeOrphans(accountID: UUID, manifest: Manifest) {
        for (folder, retained) in [("documents", Set(manifest.documentFiles.values)), ("metadata", Set([manifest.metadataFile]))] {
            let url = directory(accountID).appendingPathComponent(folder, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { continue }
            for file in files where !retained.contains(file.lastPathComponent) {
                removeAsset(file.lastPathComponent, folder: folder, accountID: accountID)
            }
        }
    }
    public func removeAccount(accountID: UUID, removeCredential: @Sendable (UUID) throws -> Void) throws {
        let saved = try snapshot(accountID: accountID)
        guard !saved.documents.values.contains(where: \.hasLocalChanges) else {
            throw AccountRemovalError.unsyncedChanges
        }
        let remaining = try accounts().filter { $0.id != accountID }
        try removeCredential(accountID)
        for url in [directory(accountID), snapshotURL(accountID), root.appendingPathComponent("Images", isDirectory: true).appendingPathComponent(accountID.uuidString, isDirectory: true)] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        loaded[accountID] = nil
        try saveAccounts(remaining)
    }
    private func snapshotURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
}

public enum LocalStorageError: Error, LocalizedError, Sendable {
    case unsupportedVersion(Int), invalidDocument
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This account uses an unsupported local storage version (\(version)). Update the app before opening it."
        case .invalidDocument: "The saved account contains an invalid document reference. Local files have been retained for recovery."
        }
    }
}

public enum AccountRemovalError: Error, LocalizedError, Sendable {
    case unsyncedChanges
    public var errorDescription: String? {
        "This account has unsynced drafts or conflicts. Export a backup if needed, then sync or resolve those changes before removing the account."
    }
}
