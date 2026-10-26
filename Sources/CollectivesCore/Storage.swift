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

/// One atomic snapshot per account keeps edits and their base revision together.
public actor LocalStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    private func read<T: Decodable>(_ type: T.Type, at url: URL, fallback: () -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback() }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public func accounts() throws -> [Account] {
        try read([Account].self, at: root.appendingPathComponent("accounts.json"), fallback: { [] })
    }
    public func saveAccounts(_ accounts: [Account]) throws {
        try write(accounts, at: root.appendingPathComponent("accounts.json"))
    }
    public func snapshot(accountID: UUID) throws -> AccountSnapshot {
        try read(AccountSnapshot.self, at: snapshotURL(accountID), fallback: { AccountSnapshot() })
    }
    public func saveSnapshot(_ snapshot: AccountSnapshot, accountID: UUID) throws {
        try write(snapshot, at: snapshotURL(accountID))
    }
    public func removeAccount(accountID: UUID, removeCredential: @Sendable (UUID) throws -> Void) throws {
        let saved = try snapshot(accountID: accountID)
        guard !saved.documents.values.contains(where: { $0.draft != nil || $0.conflict != nil }) else {
            throw AccountRemovalError.unsyncedChanges
        }
        let remaining = try accounts().filter { $0.id != accountID }
        try removeCredential(accountID)
        for url in [snapshotURL(accountID), root.appendingPathComponent("Images", isDirectory: true).appendingPathComponent(accountID.uuidString, isDirectory: true)] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try saveAccounts(remaining)
    }
    private func snapshotURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
}

public enum AccountRemovalError: Error, LocalizedError, Sendable {
    case unsyncedChanges
    public var errorDescription: String? {
        "This account has unsynced drafts or conflicts. Export a backup if needed, then sync or resolve those changes before removing the account."
    }
}
