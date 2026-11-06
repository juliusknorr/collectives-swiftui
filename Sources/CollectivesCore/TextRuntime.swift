import Foundation

public enum TextRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case unavailable, incompatible, invalidManifest, differentAccount
    public var errorDescription: String? {
        switch self {
        case .unavailable: "This server does not advertise a compatible native Text runtime. Use Markdown source editing."
        case .incompatible: "The server's Text build differs from the bundled editor. Use Markdown source editing."
        case .invalidManifest: "Text returned an invalid runtime manifest."
        case .differentAccount: "Runtime verification belongs to a different account or server."
        }
    }
}

public struct TextRuntimeManifest: Codable, Equatable, Sendable {
    public let format: Int
    public let textVersion: String
    public let sourceRevision: String
    public let codeDigest: String
    public let sessionAPI: String
    public let updateEncoding: String

    public func validate() throws {
        func hex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard format == 1, !textVersion.isEmpty, textVersion.utf8.count <= 80,
              hex(sourceRevision, count: 40), hex(codeDigest, count: 64),
              sessionAPI == "context-v1", updateEncoding == "yjs-sync-v1" else { throw TextRuntimeError.invalidManifest }
    }
}

/// A fresh native server assertion, scoped to the exact account and origin.
/// Session creation carries the digest so a server upgrade between discovery
/// and opening cannot silently accept the old runtime.
public struct VerifiedTextRuntime: Sendable {
    public let manifest: TextRuntimeManifest
    let account: Account
    init(manifest: TextRuntimeManifest, account: Account) { self.manifest = manifest; self.account = account }
}

extension CollectivesClient {
    public func verifyTextRuntime(expected: TextRuntimeManifest) async throws -> VerifiedTextRuntime {
        try expected.validate()
        let remote = try JSONDecoder().decode(TextRuntimeManifest.self, from: await textRuntimeManifest())
        try remote.validate()
        guard remote == expected else { throw TextRuntimeError.incompatible }
        return VerifiedTextRuntime(manifest: remote, account: account)
    }

    public func textSession(fileID: Int, leaseID: UUID = UUID(), verifiedRuntime: VerifiedTextRuntime) throws -> TextSessionClient {
        guard verifiedRuntime.account == account else { throw TextRuntimeError.differentAccount }
        return try TextSessionClient(client: self, fileID: fileID, leaseID: leaseID,
                                     runtimeDigest: verifiedRuntime.manifest.codeDigest)
    }
}
