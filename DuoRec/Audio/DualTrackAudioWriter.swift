@preconcurrency import AVFoundation
import CoreMedia

final class DualTrackAudioWriter {
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let microphoneInput: AVAssetWriterInput
    private let outputURL: URL

    private enum State {
        case buffering
        case writing
        case finishing
        case finished(Result<URL, Error>)
    }

    private var state: State = .buffering
    private var hasSeenSystemAudio = false
    private var hasSeenMicrophone = false
    private var pendingSamples: [(CMSampleBuffer, AudioSource)] = []
    // Capture callbacks and shutdown can arrive on different queues.
    private let lock = NSLock()
    private var finishWaiters: [(Result<URL, Error>) -> Void] = []

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        // Completed fragments remain readable if the process exits without finishing.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 48_000)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 48_000)

        systemInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
        )
        microphoneInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
        )

        let systemLabel = AVMutableMetadataItem()
        systemLabel.identifier = .quickTimeMetadataComment
        systemLabel.value = "duorec.system" as NSString
        systemInput.metadata = [systemLabel]
        let microphoneLabel = AVMutableMetadataItem()
        microphoneLabel.identifier = .quickTimeMetadataComment
        microphoneLabel.value = "duorec.microphone" as NSString
        microphoneInput.metadata = [microphoneLabel]

        systemInput.expectsMediaDataInRealTime = true
        microphoneInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(systemInput), writer.canAdd(microphoneInput) else {
            throw AudioWriterError.cannotAddInputs
        }
        writer.add(systemInput)
        writer.add(microphoneInput)
    }

    func append(_ sampleBuffer: CMSampleBuffer, source: AudioSource) throws {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .finishing, .finished: return
        case .buffering, .writing: break
        }

        switch source {
        case .system: hasSeenSystemAudio = true
        case .microphone: hasSeenMicrophone = true
        }

        if case .buffering = state {
            pendingSamples.append((sampleBuffer, source))
            if (hasSeenSystemAudio && hasSeenMicrophone) || pendingSamples.count >= 20 {
                try beginSession()
            }
            return
        }

        try appendImmediately(sampleBuffer, source: source)
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            finish { continuation.resume(with: $0) }
        }
    }

    private func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        if case .finished(let result) = state {
            lock.unlock()
            completion(result)
            return
        }
        finishWaiters.append(completion)
        if case .finishing = state {
            lock.unlock()
            return
        }

        do {
            guard writer.status == .unknown || writer.status == .writing else {
                throw writer.error ?? AudioWriterError.finishFailed
            }
            if case .buffering = state, !pendingSamples.isEmpty {
                try beginSession()
            }
            guard case .writing = state else {
                writer.cancelWriting()
                throw AudioWriterError.noAudio
            }
            guard writer.status == .writing else {
                throw writer.error ?? AudioWriterError.finishFailed
            }
            state = .finishing
            systemInput.markAsFinished()
            microphoneInput.markAsFinished()
            lock.unlock()
            writer.finishWriting { [self] in
                let result: Result<URL, Error> = writer.status == .completed
                    ? .success(outputURL)
                    : .failure(writer.error ?? AudioWriterError.finishFailed)
                completeFinish(result)
            }
        } catch {
            state = .finishing
            lock.unlock()
            completeFinish(.failure(error))
        }
    }

    private func completeFinish(_ result: Result<URL, Error>) {
        lock.lock()
        state = .finished(result)
        let waiters = finishWaiters
        finishWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0(result) }
    }

    private func beginSession() throws {
        guard case .buffering = state else { return }
        guard writer.startWriting() else {
            throw writer.error ?? AudioWriterError.startFailed
        }

        let startTime = pendingSamples
            .map { CMSampleBufferGetPresentationTimeStamp($0.0) }
            .min(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero

        writer.startSession(atSourceTime: startTime)
        state = .writing

        let buffered = pendingSamples.sorted {
            CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp($0.0),
                CMSampleBufferGetPresentationTimeStamp($1.0)
            ) < 0
        }
        pendingSamples.removeAll(keepingCapacity: false)

        for (sample, source) in buffered {
            try appendImmediately(sample, source: source)
        }
    }

    private func appendImmediately(_ sampleBuffer: CMSampleBuffer, source: AudioSource) throws {
        guard writer.status == .writing else {
            throw writer.error ?? AudioWriterError.appendFailed
        }
        let input = source == .system ? systemInput : microphoneInput
        guard input.isReadyForMoreMediaData else { return }
        guard input.append(sampleBuffer) else {
            throw writer.error ?? AudioWriterError.appendFailed
        }
    }
}

enum AudioWriterError: LocalizedError {
    case cannotAddInputs
    case startFailed
    case appendFailed
    case finishFailed
    case noAudio
    case missingTrack
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .cannotAddInputs: String(localized: "error.audio_writer.cannot_add_inputs")
        case .startFailed: String(localized: "error.audio_writer.start_failed")
        case .appendFailed: String(localized: "error.audio_writer.append_failed")
        case .finishFailed: String(localized: "error.audio_writer.finish_failed")
        case .noAudio: String(localized: "error.audio_writer.no_audio")
        case .missingTrack: String(localized: "error.audio_writer.missing_track")
        case .exportUnavailable: String(localized: "error.audio_writer.export_unavailable")
        }
    }
}
