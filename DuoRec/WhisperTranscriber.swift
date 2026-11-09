import AVFoundation
import Foundation
import whisper

nonisolated struct WhisperPiece: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

// C inference is synchronous. This flag is also read by Whisper's worker threads.
nonisolated final class WhisperCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled { throw CancellationError() } }
}

nonisolated private final class WhisperCallbacks {
    let cancellation: WhisperCancellation
    let progress: @Sendable (Double) -> Void

    init(cancellation: WhisperCancellation, progress: @escaping @Sendable (Double) -> Void) {
        self.cancellation = cancellation
        self.progress = progress
    }
}

protocol WhisperRecognizing: Sendable {
    func transcribe(url: URL, modelURL: URL, language: WhisperLanguage,
                    cancellation: WhisperCancellation,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [WhisperPiece]
}

// An actor serializes inference, including a cancelled job that is still unwinding.
// No model loading, audio decoding, or C inference runs on the UI thread.
actor WhisperTranscriber: WhisperRecognizing {
    func transcribe(url: URL, modelURL: URL, language: WhisperLanguage,
                    cancellation: WhisperCancellation,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [WhisperPiece] {
        try cancellation.check()
        let pcmURL = FileManager.default.temporaryDirectory.appendingPathComponent("DuoRec-Whisper-\(UUID()).pcm")
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        try await decodeAudio(url, to: pcmURL, cancellation: cancellation)
        try cancellation.check()

        // Map PCM from disk so long recordings do not require a second full RAM copy.
        let pcm = try Data(contentsOf: pcmURL, options: .mappedIfSafe)
        let sampleCount = pcm.count / MemoryLayout<Float>.size
        guard sampleCount > 0, sampleCount <= Int(Int32.max) else { throw WhisperError.unreadableAudio }

        var contextParams = whisper_context_default_params()
        #if arch(arm64)
        contextParams.use_gpu = true
        #else
        contextParams.use_gpu = false
        #endif
        var context = modelURL.path.withCString { whisper_init_from_file_with_params($0, contextParams) }
        // Some machines cannot initialize Metal. Retrying on CPU still uses Whisper.
        if context == nil, contextParams.use_gpu, !cancellation.isCancelled {
            contextParams.use_gpu = false
            context = modelURL.path.withCString { whisper_init_from_file_with_params($0, contextParams) }
        }
        guard let context else { try cancellation.check(); throw WhisperError.modelLoadFailed }
        defer { whisper_free(context) }
        try cancellation.check()

        let callbacks = WhisperCallbacks(cancellation: cancellation, progress: progress)
        let callbackPointer = Unmanaged.passUnretained(callbacks).toOpaque()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.translate = false
        params.no_context = true
        params.no_timestamps = false
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.suppress_nst = true
        params.abort_callback = { data in
            guard let data else { return true }
            return Unmanaged<WhisperCallbacks>.fromOpaque(data).takeUnretainedValue().cancellation.isCancelled
        }
        params.abort_callback_user_data = callbackPointer
        params.encoder_begin_callback = { _, _, data in
            guard let data else { return false }
            return !Unmanaged<WhisperCallbacks>.fromOpaque(data).takeUnretainedValue().cancellation.isCancelled
        }
        params.encoder_begin_callback_user_data = callbackPointer
        params.progress_callback = { _, _, percent, data in
            guard let data else { return }
            let callbacks = Unmanaged<WhisperCallbacks>.fromOpaque(data).takeUnretainedValue()
            if !callbacks.cancellation.isCancelled { callbacks.progress(Double(percent) / 100) }
        }
        params.progress_callback_user_data = callbackPointer

        let status = language.rawValue.withCString { languagePointer in
            params.language = languagePointer
            return withExtendedLifetime(callbacks) {
                pcm.withUnsafeBytes { bytes in
                    whisper_full(context, params, bytes.bindMemory(to: Float.self).baseAddress, Int32(sampleCount))
                }
            }
        }
        try cancellation.check()
        guard status == 0 else { throw WhisperError.recognitionFailed }
        let duration = Double(sampleCount) / 16_000
        return (0..<whisper_full_n_segments(context)).compactMap { index in
            guard let string = whisper_full_get_segment_text(context, index) else { return nil }
            let text = String(cString: string)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let start = min(duration, max(0, Double(whisper_full_get_segment_t0(context, index)) / 100))
            let end = min(duration, max(start, Double(whisper_full_get_segment_t1(context, index)) / 100))
            return WhisperPiece(start: start, end: end, text: text)
        }
    }

    private func decodeAudio(_ url: URL, to destination: URL, cancellation: WhisperCancellation) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WhisperError.unreadableAudio
        }
        try cancellation.check()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WhisperError.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? WhisperError.unreadableAudio }
        defer { reader.cancelReading() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        while let buffer = output.copyNextSampleBuffer() {
            try cancellation.check()
            try autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw WhisperError.unreadableAudio }
                var data = Data(count: CMBlockBufferGetDataLength(block))
                let status = data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw WhisperError.unreadableAudio }
                try file.write(contentsOf: data)
            }
        }
        try cancellation.check()
        guard reader.status == .completed else { throw reader.error ?? WhisperError.unreadableAudio }
    }
}
