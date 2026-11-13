import Foundation

// Stream directly into a durable partial file. Each new request starts at the
// actual file length, so pausing, network failures and app restarts retain bytes.
nonisolated final class WhisperDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64?
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var output: FileHandle?
    private var response: HTTPURLResponse?
    private var offset: Int64 = 0
    private var received: Int64 = 0
    private var responseEnd: Int64?
    private var cancelled = false

    init(destination: URL, expectedSize: Int64? = nil,
         configuration: URLSessionConfiguration = WhisperDownloader.configuration(),
         progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.configuration = configuration
        self.progress = progress
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return configuration
    }

    static func savedBytes(at url: URL) -> Int64 {
        // URL.resourceValues caches fileSize on the URL value. A partial file
        // grows while that same value remains alive, so consult the descriptor.
        guard let file = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? file.close() }
        return Int64((try? file.seekToEnd()) ?? 0)
    }

    func download(_ request: URLRequest) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                offset = Self.savedBytes(at: destination)
                received = offset
                // A completed but not yet verified download only needs local
                // integrity checking; no further range request is necessary.
                if let expectedSize, offset == expectedSize, let url = request.url {
                    lock.unlock()
                    progress(expectedSize)
                    continuation.resume(returning: HTTPURLResponse(url: url, statusCode: 200,
                                                                   httpVersion: nil, headerFields: nil)!)
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = request
                if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        let continuation = self.continuation
        let session = self.session
        // Cancellation closes the file before returning to its owner. No stale
        // callback can append bytes after a later transfer starts using it.
        try? output?.synchronize()
        try? output?.close()
        output = nil
        if case .failure = result, Self.savedBytes(at: destination) == 0 {
            try? FileManager.default.removeItem(at: destination)
        }
        self.continuation = nil
        self.session = nil
        self.task = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let active = continuation != nil && !cancelled
        let offset = self.offset
        lock.unlock()
        guard active else { completionHandler(nil); return }
        var request = request
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard continuation != nil, !cancelled else { lock.unlock(); completionHandler(.cancel); return }
        do {
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 || response.statusCode == 206 else { throw URLError(.badServerResponse) }
            var append = false
            if response.statusCode == 206 {
                guard let header = response.value(forHTTPHeaderField: "Content-Range"),
                      let range = Self.contentRange(header), range.start == offset,
                      expectedSize == nil || range.total == expectedSize else { throw URLError(.badServerResponse) }
                append = offset > 0
                responseEnd = range.end + 1
            } else {
                // If a server ignores Range, start fresh instead of appending a
                // second full file to the partial one and corrupting the model.
                offset = 0
                responseEnd = response.expectedContentLength >= 0 ? response.expectedContentLength : expectedSize
                if let expectedSize, let responseEnd, responseEnd != expectedSize { throw URLError(.badServerResponse) }
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            let file = try FileHandle(forWritingTo: destination)
            output = file
            if append { try file.seekToEnd() } else { try file.truncate(atOffset: 0) }
            received = offset
            self.response = response
            let bytes = received
            lock.unlock()
            progress(bytes)
            completionHandler(.allow)
        } catch {
            lock.unlock()
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil, !cancelled, let output else { lock.unlock(); return }
        do {
            let next = received + Int64(data.count)
            guard expectedSize == nil || next <= expectedSize!, responseEnd == nil || next <= responseEnd! else {
                throw URLError(.badServerResponse)
            }
            try output.write(contentsOf: data)
            received = next
            lock.unlock()
            progress(next)
        } catch {
            lock.unlock()
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let response = self.response
        let complete = responseEnd == nil || received == responseEnd
        lock.unlock()
        if let response, complete { finish(.success(response)) }
        else { finish(.failure(URLError(.networkConnectionLost))) }
    }

    private static func contentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let values = parts[1].split(separator: "/")
        guard values.count == 2, let total = Int64(values[1]) else { return nil }
        let bounds = values[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }
}
