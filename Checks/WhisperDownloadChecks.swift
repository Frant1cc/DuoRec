import Foundation
import CryptoKit

private final class DownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func record(_ bytes: Int64) { lock.lock(); values.append(bytes); lock.unlock() }
    func snapshot() -> [Int64] { lock.lock(); defer { lock.unlock() }; return values }
}

@main
struct WhisperDownloadChecks {
    static func main() async throws {
        let server = URL(string: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DuoRec-DownloadChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Exercise the real Foundation streaming task and delegate, including a
        // redirect like the one used by the model host. A mock progress closure
        // would not catch the async convenience method bypassing this delegate.
        let destination = root.appendingPathComponent("model.bin")
        let progress = DownloadProgress()
        let downloader = WhisperDownloader(destination: destination) { progress.record($0) }
        let response = try await downloader.download(URLRequest(url: server.appendingPathComponent("redirect")))
        precondition(response.statusCode == 200)
        let data = try Data(contentsOf: destination)
        precondition(data == Data(repeating: 0xab, count: 2_097_152))
        let updates = progress.snapshot()
        precondition(!updates.isEmpty && updates.contains(where: { $0 > 0 }) && updates.last == Int64(data.count),
                     "The transfer completed without byte progress")
        precondition(zip(updates, updates.dropFirst()).allSatisfy { $0 <= $1 })

        let rejected = root.appendingPathComponent("rejected.bin")
        do {
            _ = try await WhisperDownloader(destination: rejected, progress: { _ in })
                .download(URLRequest(url: server.appendingPathComponent("unavailable")))
            preconditionFailure("HTTP errors must fail the download")
        } catch let error as URLError { precondition(error.code == .badServerResponse) }
        precondition(!FileManager.default.fileExists(atPath: rejected.path))

        let cancelled = root.appendingPathComponent("cancelled.bin")
        let (arrivals, signal) = AsyncStream<Int64>.makeStream()
        let cancelDownloader = WhisperDownloader(destination: cancelled) { signal.yield($0) }
        let work = Task { try await cancelDownloader.download(URLRequest(url: server.appendingPathComponent("slow"))) }
        for await bytes in arrivals where bytes >= 131_072 { work.cancel(); break }
        do {
            _ = try await work.value
            preconditionFailure("Cancelled download succeeded")
        } catch is CancellationError {}
        let saved = WhisperDownloader.savedBytes(at: cancelled)
        precondition(saved >= 131_072 && saved < 2_097_152, "Pause lost the partial download")

        // A newly created downloader must resume from disk, including after an
        // app restart. Going through /redirect also exercises Range forwarding.
        let resumedProgress = DownloadProgress()
        let resumed = try await WhisperDownloader(destination: cancelled, expectedSize: 2_097_152) {
            resumedProgress.record($0)
        }.download(URLRequest(url: server.appendingPathComponent("redirect")))
        precondition(resumed.statusCode == 206, "The saved prefix was downloaded again")
        let resumedData = try Data(contentsOf: cancelled)
        precondition(resumedData == data)
        precondition(resumedProgress.snapshot().first == saved)

        // Foundation caches fileSize on a URL value. Seed that cache while the
        // file is incomplete, then finish through the production downloader and
        // verify using the SAME URL value. This reproduces the post-download
        // false "incomplete model" error after a resumed transfer.
        let cachedURL = root.appendingPathComponent("cached-size.partial")
        try data.prefix(1024).write(to: cachedURL)
        let cachedSize = try cachedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        precondition(cachedSize == 1024)
        _ = try await WhisperDownloader(destination: cachedURL, expectedSize: Int64(data.count), progress: { _ in })
            .download(URLRequest(url: server.appendingPathComponent("model")))
        precondition(WhisperDownloader.savedBytes(at: cachedURL) == Int64(data.count))
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try await WhisperModelFiles.verify(cachedURL, expectedSize: Int64(data.count), sha256: checksum)

        // An ignored Range restarts the file safely; a malformed Content-Range
        // is rejected without changing the already saved bytes.
        for endpoint in ["ignore-range", "wrong-range"] {
            let partial = root.appendingPathComponent(endpoint)
            let prefix = Data(repeating: 0xab, count: 1024)
            try prefix.write(to: partial)
            do {
                let response = try await WhisperDownloader(destination: partial, expectedSize: 2_097_152, progress: { _ in })
                    .download(URLRequest(url: server.appendingPathComponent(endpoint)))
                precondition(endpoint == "ignore-range" && response.statusCode == 200)
                let contents = try Data(contentsOf: partial)
                precondition(contents == data)
            } catch let error as URLError {
                precondition(endpoint == "wrong-range" && error.code == .badServerResponse)
                let contents = try Data(contentsOf: partial)
                precondition(contents == prefix)
            }
        }

        let beforeStart = Task {
            try await WhisperDownloader(destination: cancelled, progress: { _ in })
                .download(URLRequest(url: server.appendingPathComponent("slow")))
        }
        beforeStart.cancel()
        do {
            _ = try await beforeStart.value
            preconditionFailure("Pre-cancelled download started")
        } catch is CancellationError {}

        let stalled = root.appendingPathComponent("stalled.bin")
        let configuration = WhisperDownloader.configuration()
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 2
        let started = Date()
        do {
            let request = URLRequest(url: server.appendingPathComponent("stall"), timeoutInterval: 0.5)
            _ = try await WhisperDownloader(destination: stalled, configuration: configuration, progress: { _ in }).download(request)
            preconditionFailure("Stalled download did not time out")
        } catch let error as URLError { precondition(error.code == .timedOut) }
        precondition(Date().timeIntervalSince(started) < 5)
        precondition(!FileManager.default.fileExists(atPath: stalled.path))
        print("PASS: HTTP progress, persistent Range resume, cached-size integrity verification, Range safety, errors, cancellation and timeout")
    }
}
