import Foundation

struct BoundedHTTPTransport: Sendable {
    private let session: URLSession
    private let delegate: BoundedDataDelegate

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        let delegate = BoundedDataDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard maximumResponseBytes > 0 else { throw TextSessionError.invalidMessage }
        try Task.checkCancellation()
        let cancellation = DataTaskCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task, limit: maximumResponseBytes, continuation: continuation)
                cancellation.start(task)
            }
        } onCancel: { cancellation.cancel() }
    }
}

private final class DataTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    func start(_ task: URLSessionDataTask) {
        lock.withLock {
            self.task = task
            task.resume()
            if cancelled { task.cancel() }
        }
    }
    func cancel() {
        lock.withLock { cancelled = true; task?.cancel() }
    }
}

private final class BoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let limit: Int
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
        var response: HTTPURLResponse?
        var data = Data()
        var error: (any Error)?
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func register(_ task: URLSessionDataTask, limit: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
        lock.withLock { pending[task.taskIdentifier] = Pending(limit: limit, continuation: continuation) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let allowed = lock.withLock {
            guard var entry = pending[dataTask.taskIdentifier] else { return false }
            entry.response = response as? HTTPURLResponse
            if response.expectedContentLength > entry.limit { entry.error = TextSessionError.messageTooLarge }
            pending[dataTask.taskIdentifier] = entry
            return entry.error == nil && entry.response != nil
        }
        completionHandler(allowed ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = lock.withLock {
            // Remove before appending so Data has one owner and does not copy the
            // accumulated body on every chunk.
            guard var entry = pending.removeValue(forKey: dataTask.taskIdentifier) else { return true }
            defer { pending[dataTask.taskIdentifier] = entry }
            guard entry.error == nil else { return true }
            if data.count > entry.limit - entry.data.count {
                entry.error = TextSessionError.messageTooLarge
                entry.data = Data()
            } else { entry.data.append(data) }
            return entry.error != nil
        }
        if exceeded { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = entry.error ?? error { entry.continuation.resume(throwing: error) }
        else if let response = entry.response { entry.continuation.resume(returning: (entry.data, response)) }
        else { entry.continuation.resume(throwing: TextSessionError.invalidResponse) }
    }
}
