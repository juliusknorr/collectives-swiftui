import Foundation
import Testing
@testable import CollectivesCore

private actor MetadataTransport: HTTPTransport {
    let status: Int
    let xml: String
    private(set) var requests: [URLRequest] = []
    init(status: Int = 207, xml: String) { self.status = status; self.xml = xml }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(xml.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func metadataPage(_ id: Int, folder: String = "") -> Page {
    Page(id: id, title: "Note", fileName: "Note \(id) #🌱.md", filePath: folder, collectivePath: "Collectives/Team")
}

private func metadataClient(_ transport: MetadataTransport) -> CollectivesClient {
    CollectivesClient(account: Account(serverURL: URL(string: "https://cloud.example.test/nextcloud")!, userID: "alice"),
        credential: Credential(loginName: "alice", appPassword: "secret"), transport: transport)
}

private func metadataResponse(href: String, etag: String, status: Int = 200) -> String {
    "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:getetag>\(etag)</d:getetag></d:prop><d:status>HTTP/1.1 \(status) Status</d:status></d:propstat></d:response>"
}

@Test func documentMetadataBatchesSiblingPagesAndMatchesEncodedHrefs() async throws {
    let probe = metadataClient(MetadataTransport(xml: ""))
    let pages = [metadataPage(1), metadataPage(2), metadataPage(3, folder: "Nested")]
    let firstURL = try probe.documentURL(page: pages[0])
    let secondURL = try probe.documentURL(page: pages[1])
    let transport = MetadataTransport(xml: "<d:multistatus xmlns:d=\"DAV:\">"
        + metadataResponse(href: firstURL.path(percentEncoded: true), etag: "&quot;first&quot;")
        + metadataResponse(href: secondURL.absoluteString, etag: "&quot;second&quot;")
        + "</d:multistatus>")
    let revisions = try await metadataClient(transport).documentETags(pages: pages)
    #expect(revisions == [1: "\"first\"", 2: "\"second\""])
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests.first?.httpMethod == "PROPFIND")
    #expect(requests.first?.url?.path == "/nextcloud/remote.php/dav/files/alice/Collectives/Team")
    #expect(requests.first?.value(forHTTPHeaderField: "Depth") == "1")
    #expect(requests.first?.value(forHTTPHeaderField: "Accept") == "application/xml")
    #expect(requests.first?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
}

@Test func documentMetadataIgnoresFailedPropertiesAndUntrustedHrefs() async throws {
    let probe = metadataClient(MetadataTransport(xml: ""))
    let pages = (1...5).map { metadataPage($0) }
    let urls = try pages.map { try probe.documentURL(page: $0) }
    let transport = MetadataTransport(xml: "<d:multistatus xmlns:d=\"DAV:\">"
        + metadataResponse(href: urls[0].absoluteString, etag: "&quot;valid&quot;")
        + metadataResponse(href: urls[1].absoluteString, etag: "&quot;failed&quot;", status: 404)
        + metadataResponse(href: urls[2].absoluteString.replacingOccurrences(of: "cloud.example.test", with: "other.example.test"), etag: "&quot;wrong-origin&quot;")
        + metadataResponse(href: urls[3].absoluteString, etag: "&quot;ambiguous&quot;")
        + metadataResponse(href: urls[3].absoluteString, etag: "&quot;ambiguous&quot;")
        + metadataResponse(href: urls[4].absoluteString + "?other", etag: "&quot;query&quot;")
        + "</d:multistatus>")
    #expect(try await metadataClient(transport).documentETags(pages: pages) == [1: "\"valid\""])
}

@Test func documentMetadataRejectsMalformedXMLAndHTTPFailures() async throws {
    for transport in [MetadataTransport(xml: "<d:multistatus xmlns:d=\"DAV:\"><d:response>"),
                      MetadataTransport(xml: "<multistatus xmlns=\"unrelated\"/>"),
                      MetadataTransport(status: 405, xml: "Unsupported")] {
        await #expect(throws: CollectivesError.self) {
            try await metadataClient(transport).documentETags(pages: [metadataPage(1), metadataPage(2)])
        }
    }
}

@Test func documentMetadataChecksEachSharedFolderButSkipsSinglePages() async throws {
    let transport = MetadataTransport(xml: "<multistatus xmlns=\"DAV:\"/>")
    let pages = [metadataPage(1), metadataPage(2), metadataPage(3, folder: "Nested"),
                 metadataPage(4, folder: "Nested"), metadataPage(5, folder: "Other")]
    #expect(try await metadataClient(transport).documentETags(pages: pages).isEmpty)
    #expect(await transport.requests.count == 2)
    #expect(try await metadataClient(transport).documentETags(pages: [metadataPage(1), metadataPage(1)]).isEmpty)
    #expect(await transport.requests.count == 2)
}
