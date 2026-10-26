import Foundation
import Testing
@testable import CollectivesCore

@Test func readingImageCacheSurvivesReloadAndIsolatesAccounts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID()
    let other = UUID()
    let url = URL(string: "https://cloud.example.test/remote.php/dav/files/alice/Collectives/Team%20%F0%9F%93%9A/diagram%20%231.png")!
    let cache = ReadingImageCache(root: root)
    #expect(try await cache.data(for: url, accountID: account) == nil)
    try await cache.store(Data([1, 2, 3]), for: url, accountID: account)
    #expect(try await cache.data(for: url, accountID: other) == nil)
    try await cache.store(Data([4, 5]), for: url, accountID: other)
    let reloaded = ReadingImageCache(root: root)
    #expect(try await reloaded.data(for: url, accountID: account) == Data([1, 2, 3]))
    #expect(try await reloaded.data(for: url, accountID: other) == Data([4, 5]))
    let otherURL = URL(string: "https://another.example.test/remote.php/dav/files/alice/Collectives/Team%20%F0%9F%93%9A/diagram%20%231.png")!
    #expect(try await reloaded.data(for: otherURL, accountID: account) == nil)
}

@Test func readingImageCacheUsesOpaqueFilenamesAndAtomicReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID()
    let url = URL(string: "https://cloud.example.test/private/Collective%20name/../diagram%23secret.png?token=private")!
    let cache = ReadingImageCache(root: root)
    try await cache.store(Data([1]), for: url, accountID: account)
    try await cache.store(Data([2]), for: url, accountID: account)
    let directory = root.appendingPathComponent(account.uuidString)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.count == 1)
    #expect(names[0].count == 64)
    #expect(names[0].allSatisfy { "0123456789abcdef".contains($0) })
    #expect(try await cache.data(for: url, accountID: account) == Data([2]))
}

@Test func readingImageCacheRejectsOversizedWritesWithoutReplacingExistingData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID()
    let url = URL(string: "https://cloud.example.test/image.png")!
    let cache = ReadingImageCache(root: root)
    try await cache.store(Data([1]), for: url, accountID: account)
    await #expect(throws: CollectivesError.self) {
        try await cache.store(Data(count: 12 * 1_024 * 1_024 + 1), for: url, accountID: account)
    }
    #expect(try await cache.data(for: url, accountID: account) == Data([1]))
}
