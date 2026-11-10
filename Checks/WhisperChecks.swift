import Foundation

private actor RecognitionProbe: WhisperRecognizing {
    struct Call: Sendable {
        let modelURL: URL
        let cancellation: WhisperCancellation
        let progress: @Sendable (Double) -> Void
    }
    nonisolated let arrivals: AsyncStream<Call>
    private let signal: AsyncStream<Call>.Continuation
    private var pending: [CheckedContinuation<[WhisperPiece], Error>] = []

    init() { (arrivals, signal) = AsyncStream.makeStream() }

    func transcribe(url: URL, modelURL: URL,
                    cancellation: WhisperCancellation,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [WhisperPiece] {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            signal.yield(Call(modelURL: modelURL, cancellation: cancellation, progress: progress))
        }
    }

    func complete(_ pieces: [WhisperPiece]) { pending.removeFirst().resume(returning: pieces) }
}

@main
struct WhisperChecks {
    @MainActor
    static func main() async throws {
        try checkLanguageDetectionChunks()
        checkSimplifiedChinese()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DuoRec-WhisperChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DuoRec-WhisperChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for oldLanguage in ["en", "zh", "auto"] {
            defaults.set(oldLanguage, forKey: "whisper.language")
            _ = WhisperModelStore(directory: root, defaults: defaults)
            precondition(defaults.string(forKey: "whisper.language") == nil,
                         "An old forced-language preference survived migration")
        }
        let store = WhisperModelStore(directory: root, defaults: defaults)
        precondition(store.selectedModel == .largeV3Turbo)

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
        let restored = WhisperModelStore(directory: root, defaults: defaults)
        precondition(restored.selectedModel == .small && restored.isReady)

        let probe = RecognitionProbe()
        var arrivals = probe.arrivals.makeAsyncIterator()
        let model = TranscriptionModel(models: store, engine: probe, sourceResolver: { _ in nil })
        let audio = root.appendingPathComponent("recording.mp4")
        let first = model.transcribe(url: audio, outputFolderURL: root)!
        let firstCall = await arrivals.next()!
        precondition(firstCall.modelURL == url)
        precondition(model.isWorking && model.runningModelName == "small")
        model.cancel()
        precondition(firstCall.cancellation.isCancelled)
        let second = model.transcribe(url: audio, outputFolderURL: root)!
        _ = await arrivals.next()!
        firstCall.progress(0.95)
        await probe.complete([WhisperPiece(start: 0, end: 1, text: "stale result")])
        await first.value
        precondition(model.isWorking && model.text.isEmpty && model.progress == 0)
        await probe.complete([WhisperPiece(start: 0, end: 1, text: "你好。"),
                              WhisperPiece(start: 1, end: 2, text: " Hello."),
                              WhisperPiece(start: 2, end: 3, text: "こんにちは。")])
        await second.value
        precondition(model.phase == .finished && model.text == "你好。 Hello.こんにちは。" && model.progress == 1)
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

    static func checkSimplifiedChinese() {
        let traditional = "明天上午9點開會，請準備會議材料與工作計畫。API v2.0 / Hello!"
        let simplified = "明天上午9点开会，请准备会议材料与工作计划。API v2.0 / Hello!"
        for language in ["zh", "yue"] {
            precondition(WhisperTranscriptText.normalized(traditional, languageCode: language) == simplified)
            precondition(WhisperTranscriptText.normalized(simplified, languageCode: language) == simplified)
            precondition(WhisperTranscriptText.normalized("", languageCode: language).isEmpty)
        }
        let japanese = "明日の会議資料を準備します。東京で開発について話します。"
        precondition(WhisperTranscriptText.normalized(japanese, languageCode: "ja") == japanese,
                     "Chinese script normalization changed Japanese kanji")
        for language in ["en", "fr", "ko", ""] {
            let original = "Hello! Café — API v2.0\n\(japanese)"
            precondition(WhisperTranscriptText.normalized(original, languageCode: language) == original)
        }
        print("PASS: Chinese and Cantonese use Simplified Chinese; mixed English, punctuation and Japanese are preserved")
    }

    static func checkLanguageDetectionChunks() throws {
        let params = WhisperTranscriber.transcriptionParameters()
        precondition(params.language == nil && !params.translate && !params.detect_language && params.no_context,
                     "Transcription must auto-detect and preserve the spoken language without context from previous chunks")
        let rate = WhisperAudioChunks.sampleRate
        let cancellation = WhisperCancellation()
        let speech = [Float](repeating: 0.1, count: 5 * rate)
        let pause = [Float](repeating: 0, count: rate)
        let bilingual = speech + pause + speech
        try bilingual.withUnsafeBufferPointer { samples in
            let first = try WhisperAudioChunks.next(in: samples, from: 0, cancellation: cancellation)
            precondition(first.upperBound > 5 * rate && first.upperBound < 6 * rate,
                         "A language switch after a pause must get a fresh detection window")
            let second = try WhisperAudioChunks.next(in: samples, from: first.upperBound, cancellation: cancellation)
            precondition(second.upperBound == samples.count)
        }
        for audio in [[Float](repeating: 0.1, count: 71 * rate + 7),
                      [Float](repeating: 0, count: 65 * rate),
                      [Float](repeating: 0.01, count: 77), []] {
            try audio.withUnsafeBufferPointer { samples in
                var end = 0
                while end < samples.count {
                    let range = try WhisperAudioChunks.next(in: samples, from: end, cancellation: cancellation)
                    precondition(range.lowerBound == end && range.count > 0)
                    precondition(range.count <= WhisperAudioChunks.maximumSamples)
                    end = range.upperBound
                }
                precondition(end == samples.count, "Chunking lost audio or overlapped it")
            }
        }
        cancellation.cancel()
        do {
            _ = try speech.withUnsafeBufferPointer {
                try WhisperAudioChunks.next(in: $0, from: 0, cancellation: cancellation)
            }
            preconditionFailure("Chunk planning ignored cancellation")
        } catch is CancellationError { }
        print("PASS: automatic original-language parameters, pause boundaries, bounded contiguous chunks and cancellation")
    }
}
