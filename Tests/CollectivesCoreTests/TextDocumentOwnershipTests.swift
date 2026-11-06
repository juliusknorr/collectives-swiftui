import Foundation
import Testing
@testable import CollectivesCore

@Test func textOwnershipRequiresDurableCheckpointSaveCloseAndCanonicalRevision() throws {
    var ownership = TextDocumentOwnership()
    let key = TextDocumentOwnership.Key(accountID: UUID(), pageID: 42)
    let lease = try ownership.acquire(key, windowID: UUID())
    try ownership.opened(lease)
    try ownership.edited(lease, revision: 1)
    #expect(throws: TextSessionError.invalidState) { try ownership.beginHandoff(lease, requiredVersion: 5) }
    try ownership.checkpointed(lease, revision: 1)
    try ownership.beginHandoff(lease, requiredVersion: 5)
    #expect(throws: TextSessionError.invalidState) { try ownership.edited(lease, revision: 2) }
    #expect(throws: TextSessionError.unconfirmedSave) { try ownership.saved(lease, version: 4) }
    #expect(throws: TextSessionError.unconfirmedSave) { try ownership.closed(lease) }
    try ownership.saved(lease, version: 5)
    #expect(throws: TextSessionError.unconfirmedSave) {
        try ownership.completeHandoff(lease, canonical: .init(markdown: "edit", etag: "\"new\""), expectedMarkdown: "edit")
    }
    try ownership.closed(lease)
    for canonical in [RemoteDocument(markdown: "old", etag: "\"new\""), .init(markdown: "edit", etag: nil), .init(markdown: "edit", etag: "W/\"new\"")] {
        #expect(throws: TextSessionError.unconfirmedSave) { try ownership.completeHandoff(lease, canonical: canonical, expectedMarkdown: "edit") }
        #expect(ownership.lease(for: key) == lease)
    }
    try ownership.completeHandoff(lease, canonical: .init(markdown: "edit", etag: "\"new\""), expectedMarkdown: "edit")
    #expect(ownership.isEmpty)
}

@Test func textOwnershipRejectsStaleCallbacksAndIsolatesAccounts() throws {
    var ownership = TextDocumentOwnership()
    let first = TextDocumentOwnership.Key(accountID: UUID(), pageID: 42)
    let second = TextDocumentOwnership.Key(accountID: UUID(), pageID: 42)
    let old = try ownership.acquire(first, windowID: UUID())
    let other = try ownership.acquire(second, windowID: UUID())
    #expect(throws: TextSessionError.invalidState) { try ownership.acquire(first, windowID: UUID()) }
    try ownership.opened(old)
    try ownership.beginHandoff(old, requiredVersion: 0)
    // No local edit means no outgoing Markdown save is needed.
    try ownership.closed(old)
    try ownership.completeHandoff(old, canonical: .init(markdown: "source", etag: "\"etag\""), expectedMarkdown: "source")
    let replacement = try ownership.acquire(first, windowID: UUID())
    #expect(throws: TextSessionError.staleLease) { try ownership.opened(old) }
    #expect(ownership.lease(for: first) == replacement)
    #expect(ownership.lease(for: second) == other)
}

@Test func textOwnershipRetainsAmbiguousSessionsForRecovery() throws {
    var ownership = TextDocumentOwnership()
    let key = TextDocumentOwnership.Key(accountID: UUID(), pageID: 42)
    let lease = try ownership.acquire(key, windowID: UUID())
    try ownership.requireRecovery(lease)
    #expect(ownership.phase(for: key) == .recoveryRequired)
    #expect(ownership.hasLease(accountID: key.accountID))
    #expect(throws: TextSessionError.invalidState) { try ownership.acquire(key, windowID: UUID()) }
    #expect(throws: TextSessionError.unconfirmedSave) {
        try ownership.completeHandoff(lease, canonical: .init(markdown: "source", etag: "\"etag\""), expectedMarkdown: "source")
    }
}
