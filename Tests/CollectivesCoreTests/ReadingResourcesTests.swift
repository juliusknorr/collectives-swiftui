import Foundation
import Testing
@testable import CollectivesCore

private let readingAccount = Account(serverURL: URL(string: "https://cloud.example.test/nextcloud")!, userID: "alice")
private let readingPage = Page(id: 7, title: "Notes", fileName: "Notes #1.md", filePath: "Projects", collectivePath: "Collectives/Team 📚")
private func readingClient(transport: any HTTPTransport = URLSessionTransport()) -> CollectivesClient {
    CollectivesClient(account: readingAccount, credential: Credential(loginName: "alice", appPassword: "secret"), transport: transport)
}

@Test func readingLinksResolveRelativePathsAndSpecialNames() throws {
    let document = try readingClient().documentURL(page: readingPage)
    let sibling = ReadingResources.resolve(destination: "../Other%20%231.md#overview", documentURL: document, account: readingAccount)
    #expect(sibling?.path == "/nextcloud/remote.php/dav/files/alice/Collectives/Team 📚/Other #1.md")
    #expect(sibling?.fragment == "overview")
    #expect(ReadingResources.resolve(destination: "#overview", documentURL: document, account: readingAccount)?.fragment == "overview")
    #expect(ReadingResources.resolve(destination: "https://example.org/docs", documentURL: document, account: readingAccount)?.host == "example.org")
    for destination in ["javascript:alert(1)", "data:text/html,test", "file:///etc/passwd", "https://alice:secret@example.org/", "http://example.org/", "\\evil.example/a"] {
        #expect(ReadingResources.resolve(destination: destination, documentURL: document, account: readingAccount) == nil)
    }
}

@Test func readingPageRoutingMatchesExactAccountDocumentPaths() throws {
    let document = try readingClient().documentURL(page: readingPage)
    let anchored = ReadingResources.resolve(destination: "#overview", documentURL: document, account: readingAccount)!
    #expect(ReadingResources.pageID(for: anchored, pages: [readingPage], account: readingAccount) == readingPage.id)
    #expect(ReadingResources.pageID(for: document, pages: [readingPage], account: Account(serverURL: readingAccount.serverURL, userID: "bob")) == nil)
    #expect(ReadingResources.pageID(for: URL(string: "https://evil.example" + document.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!, pages: [readingPage], account: readingAccount) == nil)
}

@Test func readingImagesRejectOtherAccountsEndpointsAndEncodedTraversal() throws {
    let document = try readingClient().documentURL(page: readingPage)
    let image = ReadingResources.resolve(destination: "images/diagram%20%231.png", documentURL: document, account: readingAccount)!
    #expect(ReadingResources.canLoadImage(at: image, account: readingAccount))
    for url in [
        "https://cloud.example.test/nextcloud/remote.php/dav/files/bob/image.png",
        "https://cloud.example.test/nextcloud/remote.php/dav/files/alice-other/image.png",
        "https://cloud.example.test/nextcloud/remote.php/dav/files/alice/%2e%2e/bob/image.png",
        "https://cloud.example.test/nextcloud/remote.php/dav/files/alice/%2fsecret.png",
        "https://cloud.example.test/nextcloud/remote.php/dav/files/alice/image.png?download=1",
        "https://cloud.example.test/nextcloud/remote.php/dav/files/alice/image.png#fragment",
        "https://cloud.example.test:444/nextcloud/remote.php/dav/files/alice/image.png",
        "https://cloud.example.test/nextcloud/index.php/logout",
        "https://evil.example/nextcloud/remote.php/dav/files/alice/image.png"
    ] {
        #expect(!ReadingResources.canLoadImage(at: URL(string: url)!, account: readingAccount))
    }
}

@Test func readingAllowsHTTPOnlyForConfiguredLocalAccount() throws {
    let local = Account(serverURL: URL(string: "http://localhost:8080")!, userID: "alice")
    let document = URL(string: "http://localhost:8080/remote.php/dav/files/alice/Notes.md")!
    #expect(ReadingResources.resolve(destination: "image.png", documentURL: document, account: local) != nil)
    #expect(ReadingResources.resolve(destination: "http://localhost:8081/image.png", documentURL: document, account: local) == nil)
    #expect(ReadingResources.resolve(destination: "http://localhost:8080/image.png", documentURL: document, account: readingAccount) == nil)
}

private actor ImageTransport: HTTPTransport {
    let data: Data
    let mime: String
    let status: Int
    private(set) var requests: [URLRequest] = []
    init(data: Data = Data([1, 2, 3]), mime: String = "image/png", status: Int = 200) {
        self.data = data; self.mime = mime; self.status = status
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!)
    }
}

@Test func imageDownloadsAuthenticateOnlyWithinAccountDAVRoot() async throws {
    let transport = ImageTransport(mime: "image/png; charset=binary")
    let client = readingClient(transport: transport)
    let document = try client.documentURL(page: readingPage)
    let image = ReadingResources.resolve(destination: "image.png", documentURL: document, account: readingAccount)!
    #expect(try await client.downloadImage(at: image) == Data([1, 2, 3]))
    await #expect(throws: CollectivesError.self) { try await client.downloadImage(at: URL(string: "https://evil.example/image.png")!) }
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
}

@Test func imageDownloadsRejectNonRasterResponsesRedirectsAndOversizedData() async throws {
    let image = URL(string: "https://cloud.example.test/nextcloud/remote.php/dav/files/alice/image.png")!
    for transport in [ImageTransport(mime: "text/html"), ImageTransport(mime: "image/svg+xml"), ImageTransport(status: 302), ImageTransport(data: Data(count: 12 * 1_024 * 1_024 + 1))] {
        await #expect(throws: CollectivesError.self) { try await readingClient(transport: transport).downloadImage(at: image) }
    }
}
