import Foundation

public enum TextSessionError: Error, Equatable, LocalizedError, Sendable {
    case staleLease, invalidState, invalidMessage, messageTooLarge, invalidResponse, unconfirmedSave
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .staleLease: "This editor session no longer owns the document."
        case .invalidState: "Finish the current editor operation before continuing."
        case .invalidMessage: "The editor sent an invalid session request."
        case .messageTooLarge: "The editor session exceeded its message size limit."
        case .invalidResponse: "Text returned an unexpected session response."
        case .unconfirmedSave: "Text has not confirmed that the document was saved."
        case .http(let code): "Text session request failed (HTTP \(code))."
        }
    }
}

/// Values cross the bridge without exposing native credentials or session tokens.
public enum TextValue: Codable, Equatable, Sendable {
    case object([String: TextValue]), array([TextValue]), string(String), integer(Int), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([TextValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: TextValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: TextValue]? { if case .object(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    var sanitized: TextValue {
        switch self {
        case .object(let values):
            .object(values.reduce(into: [:]) { result, pair in
                result[pair.key] = ["token", "sessiontoken"].contains(pair.key.lowercased())
                    ? .string("native-owned") : pair.value.sanitized
            })
        case .array(let values): .array(values.map(\.sanitized))
        default: self
        }
    }
}

public enum TextSessionCommand: Codable, Equatable, Sendable {
    case open
    case sync(version: Int)
    case push(version: Int, steps: [String], awareness: String, recoveryAttempt: Int?)
    case save(version: Int, markdown: String, documentState: String, manual: Bool)
    case close

    var operation: String {
        switch self {
        case .open: "create"
        case .sync: "sync"
        case .push: "push"
        case .save: "save"
        case .close: "close"
        }
    }

    func parameters() throws -> [String: TextValue] {
        var result: [String: TextValue] = [:]
        switch self {
        case .open, .close: break
        case .sync(let version): result["version"] = .integer(version)
        case .push(let version, let steps, let awareness, let attempt):
            guard steps.count <= 256, steps.allSatisfy({ !$0.isEmpty && Data(base64Encoded: $0) != nil }),
                  awareness.isEmpty || Data(base64Encoded: awareness) != nil,
                  attempt.map({ $0 > 0 }) ?? true else { throw TextSessionError.invalidMessage }
            result = ["version": .integer(version), "steps": .array(steps.map(TextValue.string)), "awareness": .string(awareness)]
            if let attempt { result["recoveryAttempt"] = .integer(attempt) }
        case .save(let version, let markdown, let state, let manual):
            guard version >= 0, !state.isEmpty, Data(base64Encoded: state) != nil else { throw TextSessionError.invalidMessage }
            result = ["version": .integer(version), "autosaveContent": .string(markdown),
                      "documentState": .string(state), "manualSave": .bool(manual), "force": .bool(false)]
        }
        if let version = result["version"]?.integer, version < -1 { throw TextSessionError.invalidMessage }
        return result
    }
}

public struct TextSessionReply: Codable, Equatable, Sendable {
    public let payload: TextValue
    /// HTTP 200 alone does not confirm a Text file save.
    public let saveConfirmed: Bool?
}

/// One native client per account/file/editor lease. Browser code supplies no URLs,
/// file identifiers, authentication, or real Text session credentials.
public actor TextSessionClient {
    public enum Phase: Equatable, Sendable { case idle, opening, active, closing, closed, recoveryRequired }
    public let leaseID: UUID
    public let accountID: UUID
    public let fileID: Int
    public private(set) var phase = Phase.idle
    private let client: CollectivesClient
    private let maximumMessageBytes: Int
    private let runtimeDigest: String?
    private var documentID: String?
    private var sessionID: Int?
    private var sessionToken: String?
    private var baseVersionEtag: String?
    private var inFlight: Set<String> = []

    init(client: CollectivesClient, fileID: Int, leaseID: UUID = UUID(), maximumMessageBytes: Int = 4 * 1_024 * 1_024,
         runtimeDigest: String? = nil) throws {
        guard fileID > 0, maximumMessageBytes > 0 else { throw TextSessionError.invalidMessage }
        self.client = client; self.fileID = fileID; self.leaseID = leaseID
        accountID = client.account.id; self.maximumMessageBytes = maximumMessageBytes
        self.runtimeDigest = runtimeDigest
    }

    public func send(_ command: TextSessionCommand, leaseID: UUID) async throws -> TextSessionReply {
        guard leaseID == self.leaseID else { throw TextSessionError.staleLease }
        try Task.checkCancellation()
        guard try JSONEncoder().encode(command).count <= maximumMessageBytes else { throw TextSessionError.messageTooLarge }
        let operation = command.operation
        let parameters = try command.parameters()
        // Bound before adding credentials and before allocating a network request.
        guard try JSONEncoder().encode(parameters).count <= maximumMessageBytes else { throw TextSessionError.messageTooLarge }
        let path: [String]
        var body = parameters
        switch command {
        case .open:
            guard phase == .idle else { throw TextSessionError.invalidState }
            path = ["file", String(fileID), "create"]
            if let runtimeDigest { body["runtimeDigest"] = .string(runtimeDigest) }
            phase = .opening
        case .close:
            guard [.active, .recoveryRequired].contains(phase), inFlight.isEmpty,
                  let documentID, let sessionID, let sessionToken else { throw TextSessionError.invalidState }
            path = [documentID, operation]
            body = ["documentId": .string(documentID), "sessionId": .integer(sessionID), "sessionToken": .string(sessionToken)]
            phase = .closing
        default:
            guard phase == .active, !inFlight.contains(operation), let documentID, let sessionID, let sessionToken,
                  let baseVersionEtag else { throw TextSessionError.invalidState }
            guard !(operation == "save" && inFlight.contains("push")),
                  !(operation == "push" && inFlight.contains("save")) else { throw TextSessionError.invalidState }
            path = [documentID, operation]
            body["documentId"] = .string(documentID); body["sessionId"] = .integer(sessionID)
            body["sessionToken"] = .string(sessionToken); body["baseVersionEtag"] = .string(baseVersionEtag)
            if let runtimeDigest { body["runtimeDigest"] = .string(runtimeDigest) }
        }
        inFlight.insert(operation)
        defer { inFlight.remove(operation) }
        do {
            let encoded = try JSONEncoder().encode(body)
            guard encoded.count <= maximumMessageBytes else { throw TextSessionError.messageTooLarge }
            let data = try await client.sendTextSession(path: path, method: command == .open ? "PUT" : "POST",
                                                        body: encoded, maximumResponseBytes: maximumMessageBytes)
            try Task.checkCancellation()
            let expected: Phase = command == .open ? .opening : (command == .close ? .closing : .active)
            guard phase == expected else { throw TextSessionError.staleLease }
            let payload = try JSONDecoder().decode(TextValue.self, from: data)
            if command == .open {
                guard let object = payload.object, let document = object["document"]?.object,
                      let id = document["id"]?.string, !id.isEmpty,
                      let session = object["session"]?.object, let sid = session["id"]?.integer, sid > 0,
                      let token = session["token"]?.string, !token.isEmpty,
                      let base = document["baseVersionEtag"]?.string, !base.isEmpty else { throw TextSessionError.invalidResponse }
                // Validate the opaque ID as a single path component before retaining credentials.
                _ = try ServerAddress.append([id], to: client.account.serverURL)
                documentID = id; sessionID = sid; sessionToken = token; baseVersionEtag = base
                phase = .active
            } else if command == .close {
                guard payload == .array([]) || payload == .object([:]) else { throw TextSessionError.invalidResponse }
                phase = .closed
                sessionToken = nil
            }
            let confirmed: Bool?
            if case .save(let version, _, _, _) = command {
                guard let savedVersion = payload.object?["document"]?.object?["lastSavedVersion"]?.integer else {
                    throw TextSessionError.invalidResponse
                }
                confirmed = savedVersion >= version
            } else { confirmed = nil }
            return TextSessionReply(payload: payload.sanitized, saveConfirmed: confirmed)
        } catch {
            if command == .open || command == .close {
                // A lost reply may have created/closed a server session. Never replay it implicitly.
                phase = .recoveryRequired
            } else if let failure = error as? TextSessionError, case .http(let status) = failure,
                      [401, 403, 404, 412].contains(status) {
                phase = .recoveryRequired
            }
            throw error
        }
    }
}
