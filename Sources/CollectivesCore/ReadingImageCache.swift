import CryptoKit
import Foundation

public actor ReadingImageCache {
    private let root: URL
    private let maximumSize = 12 * 1_024 * 1_024

    public init(root: URL) { self.root = root }

    public func data(for url: URL, accountID: UUID) throws -> Data? {
        let file = cacheURL(for: url, accountID: accountID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumSize else {
            throw CollectivesError.invalidResponse
        }
        let data = try Data(contentsOf: file)
        guard data.count <= maximumSize else { throw CollectivesError.invalidResponse }
        return data
    }

    public func store(_ data: Data, for url: URL, accountID: UUID) throws {
        guard data.count <= maximumSize else { throw CollectivesError.invalidResponse }
        let file = cacheURL(for: url, accountID: accountID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func cacheURL(for url: URL, accountID: UUID) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(accountID.uuidString, isDirectory: true).appendingPathComponent(key)
    }
}
