import AVFoundation
import Foundation
import whisper

nonisolated struct WhisperPiece: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

nonisolated enum WhisperTranscriptText {
    static func normalized(_ text: String, languageCode: String) -> String {
        // Whisper's Chinese language token does not distinguish script variants.
        // Normalize Chinese/Cantonese only; applying this to Japanese would also
        // change its kanji (for example 準備), which must remain in the source form.
        guard languageCode == "zh" || languageCode == "yue" else { return text }
        return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }
}

// Skip near-silence, retaining original sample positions and 200 ms of padding.
// Short pauses stay inside a ~12–30 s window; longer pauses still separate
// utterances so a new language can be detected even after a short sentence.
// This conservative energy gate is not a speech/noise classifier.
nonisolated enum WhisperAudioChunks {
    static let sampleRate = 16_000
    static let maximumSamples = 30 * sampleRate
    static let silenceRMS: Float = 0.0003

    static func next(in samples: UnsafeBufferPointer<Float>, from start: Int,
                     cancellation: WhisperCancellation) throws -> Range<Int>? {
        try cancellation.check()
        let frameSize = sampleRate / 50 // 20 ms
        let padding = sampleRate / 5
        let minimumSamples = 12 * sampleRate
        let pauseSamples = sampleRate * 3 / 5
        let utterancePauseSamples = sampleRate * 11 / 10

        func isAudible(_ frameStart: Int, _ frameEnd: Int) -> Bool {
            var energy = 0.0
            for index in frameStart..<frameEnd {
                let sample = Double(samples[index])
                energy += sample * sample
            }
            return energy > Double(silenceRMS) * Double(silenceRMS) * Double(frameEnd - frameStart)
        }

        var firstAudible = start
        while firstAudible < samples.count {
            try cancellation.check()
            let end = min(samples.count, firstAudible + frameSize)
            if isAudible(firstAudible, end) { break }
            firstAudible = end
        }
        guard firstAudible < samples.count else { return nil }
        let lowerBound = max(start, firstAudible - padding)
        let limit = min(samples.count, lowerBound + maximumSamples)
        var lastAudibleEnd = firstAudible
        for frameStart in stride(from: firstAudible, to: limit, by: frameSize) {
            try cancellation.check()
            let frameEnd = min(limit, frameStart + frameSize)
            if isAudible(frameStart, frameEnd) {
                lastAudibleEnd = frameEnd
            } else {
                let silenceSamples = frameEnd - lastAudibleEnd
                if silenceSamples >= utterancePauseSamples ||
                    (lastAudibleEnd - lowerBound >= minimumSamples && silenceSamples >= pauseSamples) {
                    return lowerBound..<min(limit, lastAudibleEnd + padding)
                }
            }
        }
        return lowerBound..<min(limit, lastAudibleEnd + padding)
    }
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
    func transcribe(url: URL, modelURL: URL,
                    cancellation: WhisperCancellation,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [WhisperPiece]
}

// An actor serializes inference, including a cancelled job that is still unwinding.
// No model loading, audio decoding, or C inference runs on the UI thread.
actor WhisperTranscriber: WhisperRecognizing {
    func transcribe(url: URL, modelURL: URL,
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

        // Entirely silent tracks do not need to load the model at all.
        let firstRange = try pcm.withUnsafeBytes {
            try WhisperAudioChunks.next(in: $0.bindMemory(to: Float.self), from: 0, cancellation: cancellation)
        }
        guard let firstRange else { progress(1); return [] }

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

        return try pcm.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Float.self)
            var pieces: [WhisperPiece] = []
            var nextRange: Range<Int>? = firstRange
            while let range = nextRange {
                try cancellation.check()
                progress(Double(range.lowerBound) / Double(sampleCount))
                let callbacks = WhisperCallbacks(cancellation: cancellation) { fraction in
                    progress((Double(range.lowerBound) + Double(range.count) * fraction) / Double(sampleCount))
                }
                var params = Self.transcriptionParameters()
                Self.setCallbacks(&params, pointer: Unmanaged.passUnretained(callbacks).toOpaque())
                let status = withExtendedLifetime(callbacks) {
                    whisper_full(context, params, samples.baseAddress!.advanced(by: range.lowerBound), Int32(range.count))
                }
                try cancellation.check()
                guard status == 0 else { throw WhisperError.recognitionFailed }
                let offset = Double(range.lowerBound) / Double(WhisperAudioChunks.sampleRate)
                let duration = Double(range.count) / Double(WhisperAudioChunks.sampleRate)
                let languageCode = whisper_lang_str(whisper_full_lang_id(context)).map { String(cString: $0) } ?? ""
                // whisper_full replaces its results on each call. Read them
                // before processing the next chunk and restore track-relative time.
                for index in 0..<whisper_full_n_segments(context) {
                    guard let string = whisper_full_get_segment_text(context, index) else { continue }
                    let text = WhisperTranscriptText.normalized(String(cString: string), languageCode: languageCode)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let t0 = min(duration, max(0, Double(whisper_full_get_segment_t0(context, index)) / 100))
                    let t1 = min(duration, max(t0, Double(whisper_full_get_segment_t1(context, index)) / 100))
                    pieces.append(WhisperPiece(start: offset + t0, end: offset + t1, text: text))
                }
                progress(Double(range.upperBound) / Double(sampleCount))
                nextRange = try WhisperAudioChunks.next(in: samples, from: range.upperBound, cancellation: cancellation)
            }
            progress(1)
            return pieces
        }
    }

    nonisolated static func transcriptionParameters() -> whisper_full_params {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        // nil auto-detects all supported languages on every whisper_full call.
        // detect_language=true would only detect and return without transcribing.
        params.language = nil
        params.detect_language = false
        params.translate = false
        params.no_context = true
        params.no_timestamps = false
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.suppress_nst = true
        return params
    }

    nonisolated private static func setCallbacks(_ params: inout whisper_full_params,
                                                pointer: UnsafeMutableRawPointer) {
        params.abort_callback = { data in
            guard let data else { return true }
            return Unmanaged<WhisperCallbacks>.fromOpaque(data).takeUnretainedValue().cancellation.isCancelled
        }
        params.abort_callback_user_data = pointer
        params.encoder_begin_callback = { _, _, data in
            guard let data else { return false }
            return !Unmanaged<WhisperCallbacks>.fromOpaque(data).takeUnretainedValue().cancellation.isCancelled
        }
        params.encoder_begin_callback_user_data = pointer
        params.progress_callback = { _, _, percent, data in
            guard let data else { return }
            let callbacks = Unmanaged<WhisperCallbacks>.fromOpaque(data).takeUnretainedValue()
            if !callbacks.cancellation.isCancelled { callbacks.progress(Double(percent) / 100) }
        }
        params.progress_callback_user_data = pointer
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
