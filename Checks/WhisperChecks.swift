import Foundation

private actor RecognitionProbe: WhisperRecognizing {
    struct Call: Sendable {
        let modelURL: URL
        let language: WhisperLanguage
        let cancellation: WhisperCancellation
        let progress: @Sendable (Double) -> Void
    }
    nonisolated let arrivals: AsyncStream<Call>
    private let signal: AsyncStream<Call>.Continuation
    private var pending: [CheckedContinuation<[WhisperPiece], Error>] = []

    init() { (arrivals, signal) = AsyncStream.makeStream() }

    func transcribe(url: URL, modelURL: URL, language: WhisperLanguage,
                    cancellation: WhisperCancellation,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [WhisperPiece] {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            signal.yield(Call(modelURL: modelURL, language: language, cancellation: cancellation, progress: progress))
        }
    }

    func complete(_ pieces: [WhisperPiece]) { pending.removeFirst().resume(returning: pieces) }
}

@main
struct WhisperChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DuoRec-WhisperChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DuoRec-WhisperChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhisperModelStore(directory: root, defaults: defaults)
        precondition(store.selectedModel == .largeV3Turbo && store.language == .automatic)

        // Incomplete/HTML error responses must never become installed models.
        let invalid = root.appendingPathComponent("invalid.bin")
        try Data("<html>download error</html>".utf8).write(to: invalid)
        let importing = store.importModel(.small, from: invalid)!
        precondition(store.isTransferring)
        precondition(store.importModel(.medium, from: invalid) == nil)
        await importing.value
        precondition(!store.isTransferring && store.installed.isEmpty && store.errorMessage != nil)
        precondition(!FileManager.default.fileExists(atPath: store.modelURL(for: .small).path))
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(remainingFiles.allSatisfy { !$0.hasSuffix(".importing") })

        let partial = store.partialURL(for: .medium)
        try Data(repeating: 0x42, count: 2048).write(to: partial)
        let resumedStore = WhisperModelStore(directory: root, defaults: defaults)
        precondition(resumedStore.pausedDownloads[.medium] == 2048,
                     "App restart did not recover the paused download")
        resumedStore.discardPartial(.medium)
        precondition(resumedStore.pausedDownloads[.medium] == nil)
        precondition(!FileManager.default.fileExists(atPath: partial.path))

        // Sparse stand-ins exercise cache/readiness policy without downloading weights.
        let url = store.modelURL(for: .small)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(WhisperModel.small.byteCount))
        try file.close()
        store.select(.small)
        store.refreshInstalled()
        precondition(!store.isReady, "An unverified model was accepted")
        try WhisperModel.small.sha256.write(to: url.appendingPathExtension("verified"), atomically: true, encoding: .utf8)
        store.refreshInstalled()
        precondition(store.isReady)
        store.language = .english
        let restored = WhisperModelStore(directory: root, defaults: defaults)
        precondition(restored.selectedModel == .small && restored.language == .english && restored.isReady)

        let probe = RecognitionProbe()
        var arrivals = probe.arrivals.makeAsyncIterator()
        let model = TranscriptionModel(models: store, engine: probe, sourceResolver: { _ in nil })
        let audio = root.appendingPathComponent("recording.mp4")
        let first = model.transcribe(url: audio, outputFolderURL: root)!
        let firstCall = await arrivals.next()!
        precondition(firstCall.modelURL == url && firstCall.language == .english)
        precondition(model.isWorking && model.runningModelName == "small")
        model.cancel()
        precondition(firstCall.cancellation.isCancelled)
        let second = model.transcribe(url: audio, outputFolderURL: root)!
        _ = await arrivals.next()!
        firstCall.progress(0.95)
        await probe.complete([WhisperPiece(start: 0, end: 1, text: "stale result")])
        await first.value
        precondition(model.isWorking && model.text.isEmpty && model.progress == 0)
        await probe.complete([WhisperPiece(start: 0, end: 1, text: "Hello"),
                              WhisperPiece(start: 1, end: 2, text: " world.")])
        await second.value
        precondition(model.phase == .finished && model.text == "Hello world." && model.progress == 1)
        precondition(!model.isWorking)

        store.remove(.small)
        precondition(!store.isReady)
        let missing = model.transcribe(url: audio, outputFolderURL: root)!
        await missing.value
        precondition(model.phase == .failed && model.errorMessage != nil)

        // A failed checksum must retain a completed download for diagnostics
        // and re-verification, rather than forcing a gigabyte-sized re-download.
        let failedDownload = store.partialURL(for: .small)
        FileManager.default.createFile(atPath: failedDownload.path, contents: nil)
        let incomplete = try FileHandle(forWritingTo: failedDownload)
        try incomplete.truncate(atOffset: UInt64(WhisperModel.small.byteCount))
        try incomplete.close()
        await store.download(.small)!.value // Full-size sparse fixture; no network.
        precondition(store.errorMessage != nil && !store.isReady)
        precondition(WhisperDownloader.savedBytes(at: failedDownload) == WhisperModel.small.byteCount)
        precondition(store.pausedDownloads[.small] == WhisperModel.small.byteCount)
        store.discardPartial(.small)
        print("PASS: Whisper cache verification, import failure cleanup, preferences, missing model, inference cancellation and stale-result isolation")
    }
}
