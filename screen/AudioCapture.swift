@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

enum AudioSource {
    case system
    case microphone
}

final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: DualTrackAudioWriter?
    private let microphoneGainDB: Float
    private let levelHandler: @Sendable (AudioSource, Double) -> Void
    private let errorHandler: @Sendable (String) -> Void

    init(
        writer: DualTrackAudioWriter?,
        microphoneGainDB: Float,
        levelHandler: @escaping @Sendable (AudioSource, Double) -> Void,
        errorHandler: @escaping @Sendable (String) -> Void
    ) {
        self.writer = writer
        self.microphoneGainDB = microphoneGainDB
        self.levelHandler = levelHandler
        self.errorHandler = errorHandler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let source: AudioSource
        switch outputType {
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }

        if source == .microphone, microphoneGainDB > 0 {
            AudioGainProcessor.applyGain(to: sampleBuffer, decibels: microphoneGainDB)
        }
        levelHandler(source, AudioLevelMeter.normalizedLevel(for: sampleBuffer))

        do {
            try writer?.append(sampleBuffer, source: source)
        } catch {
            errorHandler(
                String(
                    format: String(localized: "error.write_recording_detail"),
                    error.localizedDescription
                )
            )
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errorHandler(
            String(
                format: String(localized: "error.system_stopped_recording_detail"),
                error.localizedDescription
            )
        )
    }

    func finish() async throws -> URL {
        guard let writer else { throw AudioWriterError.noAudio }
        return try await writer.finish()
    }
}

final class DualTrackAudioWriter {
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let microphoneInput: AVAssetWriterInput
    private let outputURL: URL

    private var hasStartedSession = false
    private var hasSeenSystemAudio = false
    private var hasSeenMicrophone = false
    private var pendingSamples: [(CMSampleBuffer, AudioSource)] = []
    private var isFinishing = false
    // Capture callbacks and shutdown can arrive on different queues.
    private let lock = NSLock()
    private var finishResult: Result<URL, Error>?
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
        guard !isFinishing else { return }

        switch source {
        case .system: hasSeenSystemAudio = true
        case .microphone: hasSeenMicrophone = true
        }

        if !hasStartedSession {
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
        if let finishResult {
            lock.unlock()
            completion(finishResult)
            return
        }
        finishWaiters.append(completion)
        guard !isFinishing else {
            lock.unlock()
            return
        }
        isFinishing = true

        do {
            guard writer.status == .unknown || writer.status == .writing else {
                throw writer.error ?? AudioWriterError.finishFailed
            }
            if !hasStartedSession, !pendingSamples.isEmpty {
                try beginSession()
            }
            guard hasStartedSession else {
                writer.cancelWriting()
                throw AudioWriterError.noAudio
            }
            guard writer.status == .writing else {
                throw writer.error ?? AudioWriterError.finishFailed
            }
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
            lock.unlock()
            completeFinish(.failure(error))
        }
    }

    private func completeFinish(_ result: Result<URL, Error>) {
        lock.lock()
        finishResult = result
        let waiters = finishWaiters
        finishWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0(result) }
    }

    private func beginSession() throws {
        guard !hasStartedSession else { return }
        guard writer.startWriting() else {
            throw writer.error ?? AudioWriterError.startFailed
        }

        let startTime = pendingSamples
            .map { CMSampleBufferGetPresentationTimeStamp($0.0) }
            .min(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero

        writer.startSession(atSourceTime: startTime)
        hasStartedSession = true

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

enum AudioMixer {
    static func mixTracks(in sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw AudioWriterError.missingTrack
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(tracks.count > 1 && index == 0 ? 0.5 : 1.0, at: .zero)
            return parameters
        }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioWriterError.exportUnavailable
        }
        exporter.audioMix = mix
        do {
            try await exporter.export(to: destinationURL, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
}

// DualTrackAudioWriter adds system audio first and microphone audio second.
// Exporting one track at a time keeps the speech recognizer from hearing the
// other source while preserving the ordinary mixed M4A for playback.
enum AudioTrackExtractor {
    struct Track {
        let source: AudioSource
        let url: URL
        let startTime: TimeInterval
        let firstMediaTime: TimeInterval
    }

    static func companionURL(for mixedRecordingURL: URL) -> URL {
        mixedRecordingURL.deletingPathExtension().appendingPathExtension("tracks.mov")
    }

    static func extractTracks(in sourceURL: URL, to directoryURL: URL) async throws -> [Track] {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioWriterError.missingTrack }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var extracted: [Track] = []
        do {
            for (index, track) in tracks.prefix(2).enumerated() {
                let timeRange = try await track.load(.timeRange)
                guard timeRange.duration.isNumeric, timeRange.duration.seconds > 0 else { continue }
                let segments = try await track.load(.segments)
                let firstMediaTime = segments.first(where: { !$0.isEmpty })?
                    .timeMapping.target.start.seconds ?? timeRange.start.seconds
                let source = await source(for: track, fallbackIndex: index)
                let composition = AVMutableComposition()
                guard let isolatedTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw AudioWriterError.cannotAddInputs }
                try isolatedTrack.insertTimeRange(timeRange, of: track, at: .zero)

                let destination = directoryURL.appendingPathComponent("track-\(index).m4a")
                guard let exporter = AVAssetExportSession(
                    asset: composition,
                    presetName: AVAssetExportPresetAppleM4A
                ) else { throw AudioWriterError.exportUnavailable }
                do {
                    try await exporter.export(to: destination, as: .m4a)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                extracted.append(Track(
                    source: source,
                    url: destination,
                    startTime: timeRange.start.seconds,
                    firstMediaTime: firstMediaTime
                ))
            }
            return extracted
        } catch {
            for track in extracted { try? FileManager.default.removeItem(at: track.url) }
            throw error
        }
    }

    private static func source(for track: AVAssetTrack, fallbackIndex: Int) async -> AudioSource {
        if let metadata = try? await track.load(.metadata),
           let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataComment).first,
           let label = try? await item.load(.stringValue) {
            if label == "duorec.system" { return .system }
            if label == "duorec.microphone" { return .microphone }
        }
        return fallbackIndex == 0 ? .system : .microphone
    }
}

private enum AudioGainProcessor {
    static func applyGain(to sampleBuffer: CMSampleBuffer, decibels: Float) {
        guard decibels > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM
        else { return }

        let multiplier = pow(10.0, Double(decibels) / 20.0)
        var retainedBlockBuffer: CMBlockBuffer?
        let maximumBuffers = max(Int(description.mChannelsPerFrame), 1)
        let sizeNeeded = MemoryLayout<AudioBufferList>.size
            + max(maximumBuffers - 1, 0) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let audioBufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let isFloat = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (description.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }

            if isFloat && description.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let values = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count {
                    values[index] = Float(limited(Double(values[index]) * multiplier))
                }
            } else if isFloat && description.mBitsPerChannel == 64 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Double>.size
                let values = data.bindMemory(to: Double.self, capacity: count)
                for index in 0..<count {
                    values[index] = limited(values[index] * multiplier)
                }
            } else if isSignedInteger && description.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let values = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count {
                    let normalized = Double(values[index]) / Double(Int16.max)
                    values[index] = Int16(limited(normalized * multiplier) * Double(Int16.max))
                }
            } else if isSignedInteger && description.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                let values = data.bindMemory(to: Int32.self, capacity: count)
                for index in 0..<count {
                    let normalized = Double(values[index]) / Double(Int32.max)
                    values[index] = Int32(limited(normalized * multiplier) * Double(Int32.max))
                }
            }
        }
    }

    private static func limited(_ sample: Double) -> Double {
        min(max(sample, -1), 1)
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

private enum AudioLevelMeter {
    static func normalizedLevel(for sampleBuffer: CMSampleBuffer) -> Double {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
            description.mFormatID == kAudioFormatLinearPCM
        else { return 0 }

        var retainedBlockBuffer: CMBlockBuffer?
        let maximumBuffers = max(Int(description.mChannelsPerFrame), 1)
        let sizeNeeded = MemoryLayout<AudioBufferList>.size
            + max(maximumBuffers - 1, 0) * MemoryLayout<AudioBuffer>.size

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let audioBufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return 0 }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        var sumSquares = 0.0
        var sampleCount = 0
        let isFloat = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (description.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }

            if isFloat && description.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let values = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count {
                    let value = Double(values[index])
                    sumSquares += value * value
                }
                sampleCount += count
            } else if isFloat && description.mBitsPerChannel == 64 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Double>.size
                let values = data.bindMemory(to: Double.self, capacity: count)
                for index in 0..<count {
                    let value = values[index]
                    sumSquares += value * value
                }
                sampleCount += count
            } else if isSignedInteger && description.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let values = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count {
                    let value = Double(values[index]) / Double(Int16.max)
                    sumSquares += value * value
                }
                sampleCount += count
            } else if isSignedInteger && description.mBitsPerChannel == 24 {
                let count = Int(buffer.mDataByteSize) / 3
                let bytes = data.bindMemory(to: UInt8.self, capacity: count * 3)
                for index in 0..<count {
                    let offset = index * 3
                    var raw = Int32(bytes[offset])
                        | (Int32(bytes[offset + 1]) << 8)
                        | (Int32(bytes[offset + 2]) << 16)
                    if (raw & 0x0080_0000) != 0 {
                        raw |= ~0x00FF_FFFF
                    }
                    let value = Double(raw) / 8_388_607.0
                    sumSquares += value * value
                }
                sampleCount += count
            } else if isSignedInteger && description.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                let values = data.bindMemory(to: Int32.self, capacity: count)
                for index in 0..<count {
                    let value = Double(values[index]) / Double(Int32.max)
                    sumSquares += value * value
                }
                sampleCount += count
            }
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}
