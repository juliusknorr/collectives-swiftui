import Foundation
import Testing
@testable import CollectivesCore

private final class BoundedResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bounded.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = request.url!.path == "/known-size" ? ["Content-Length": "1024"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 512))
        client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 512))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(arguments: ["known-size", "unknown-size"])
func boundedSessionRejectsOversizedHeadersAndStreamedBodies(path: String) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BoundedResponseProtocol.self]
    let transport = BoundedHTTPTransport(configuration: configuration)
    let request = URLRequest(url: URL(string: "https://bounded.example.test/\(path)")!)
    await #expect(throws: TextSessionError.messageTooLarge) { try await transport.send(request, maximumResponseBytes: 700) }
}

@Test func boundedSessionAcceptsExactLimitAndCancelsBeforeStarting() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BoundedResponseProtocol.self]
    let transport = BoundedHTTPTransport(configuration: configuration)
    let request = URLRequest(url: URL(string: "https://bounded.example.test/unknown-size")!)
    let (body, response) = try await transport.send(request, maximumResponseBytes: 1024)
    #expect(body.count == 1024)
    #expect(body[0] == 1 && body[1023] == 2)
    #expect(response.statusCode == 200)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await transport.send(request, maximumResponseBytes: 1024)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
