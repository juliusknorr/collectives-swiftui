import Foundation

/// A page-bound lease for messages from the experimental offline editor.
public struct EmbeddedTextSession: Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let pageID: Int
    public let initialMarkdown: String
    public private(set) var revision = 0

    public init(accountID: UUID, pageID: Int, markdown: String, id: UUID = UUID()) {
        self.id = id; self.accountID = accountID; self.pageID = pageID
        initialMarkdown = markdown
    }

    public mutating func accept(sessionID: UUID, revision: Int) -> Bool {
        guard sessionID == id, revision > self.revision else { return false }
        self.revision = revision
        return true
    }
}

extension AccountSnapshot {
    public mutating func rememberTextSource(pageID: Int, markdown: String) {
        if textSourceBackups?[String(pageID)] != nil { return }
        if textSourceBackups == nil { textSourceBackups = [:] }
        textSourceBackups?[String(pageID)] = markdown
    }
}
