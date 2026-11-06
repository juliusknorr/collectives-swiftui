import Foundation

/// Ownership outlives a window when a session still needs recovery. Removing a
/// window must never make its document eligible for a WebDAV draft upload.
public struct TextDocumentOwnership: Sendable {
    public struct Key: Hashable, Sendable {
        public let accountID: UUID
        public let pageID: Int
        public init(accountID: UUID, pageID: Int) { self.accountID = accountID; self.pageID = pageID }
    }
    public struct Lease: Equatable, Sendable {
        public let id: UUID
        public let key: Key
        public let windowID: UUID
    }
    public enum Phase: Sendable { case opening, editing, finishing, recoveryRequired }
    private struct Entry: Sendable {
        let lease: Lease
        var phase = Phase.opening
        var latestRevision = 0
        var checkpointRevision = 0
        var savedVersion: Int?
        var requiredVersion: Int?
        var closed = false
    }
    private var entries: [Key: Entry] = [:]
    public init() {}
    public var isEmpty: Bool { entries.isEmpty }
    public func lease(for key: Key) -> Lease? { entries[key]?.lease }
    public func hasLease(accountID: UUID) -> Bool { entries.keys.contains { $0.accountID == accountID } }
    public func phase(for key: Key) -> Phase? { entries[key]?.phase }

    public mutating func acquire(_ key: Key, windowID: UUID) throws -> Lease {
        guard entries[key] == nil else { throw TextSessionError.invalidState }
        let lease = Lease(id: UUID(), key: key, windowID: windowID)
        entries[key] = Entry(lease: lease)
        return lease
    }
    public mutating func opened(_ lease: Lease) throws {
        var entry = try entry(for: lease)
        guard entry.phase == .opening else { throw TextSessionError.invalidState }
        entry.phase = .editing
        entries[lease.key] = entry
    }
    public mutating func edited(_ lease: Lease, revision: Int) throws {
        var entry = try entry(for: lease)
        guard entry.phase == .editing, revision > entry.latestRevision else { throw TextSessionError.invalidState }
        entry.latestRevision = revision
        entries[lease.key] = entry
    }
    public mutating func checkpointed(_ lease: Lease, revision: Int) throws {
        var entry = try entry(for: lease)
        guard revision >= entry.checkpointRevision, revision <= entry.latestRevision else { throw TextSessionError.invalidState }
        entry.checkpointRevision = revision
        entries[lease.key] = entry
    }
    public mutating func beginHandoff(_ lease: Lease, requiredVersion: Int) throws {
        var entry = try entry(for: lease)
        guard entry.phase == .editing, entry.checkpointRevision == entry.latestRevision,
              requiredVersion >= 0 else { throw TextSessionError.invalidState }
        entry.phase = .finishing
        entry.requiredVersion = requiredVersion
        entries[lease.key] = entry
    }
    public mutating func saved(_ lease: Lease, version: Int) throws {
        var entry = try entry(for: lease)
        guard entry.phase == .finishing, let required = entry.requiredVersion, version >= required else {
            throw TextSessionError.unconfirmedSave
        }
        entry.savedVersion = version
        entries[lease.key] = entry
    }
    public mutating func closed(_ lease: Lease) throws {
        var entry = try entry(for: lease)
        guard entry.phase == .finishing, entry.savedVersion != nil || entry.latestRevision == 0 else { throw TextSessionError.unconfirmedSave }
        entry.closed = true
        entries[lease.key] = entry
    }
    /// Call only after persisting the refreshed native snapshot. Failed storage
    /// must leave this ownership intact for recovery.
    public mutating func completeHandoff(_ lease: Lease, canonical: RemoteDocument, expectedMarkdown: String) throws {
        let entry = try entry(for: lease)
        guard entry.phase == .finishing, entry.closed,
              canonical.markdown == expectedMarkdown, let etag = canonical.etag,
              !etag.isEmpty, !etag.hasPrefix("W/") else { throw TextSessionError.unconfirmedSave }
        entries.removeValue(forKey: lease.key)
    }
    public mutating func requireRecovery(_ lease: Lease) throws {
        var entry = try entry(for: lease)
        entry.phase = .recoveryRequired
        entries[lease.key] = entry
    }
    private func entry(for lease: Lease) throws -> Entry {
        guard let entry = entries[lease.key], entry.lease == lease else { throw TextSessionError.staleLease }
        return entry
    }
}
