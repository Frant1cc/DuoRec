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

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

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

        systemInput.expectsMediaDataInRealTime = true
        microphoneInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(systemInput), writer.canAdd(microphoneInput) else {
            throw AudioWriterError.cannotAddInputs
        }
        writer.add(systemInput)
        writer.add(microphoneInput)
    }

    func append(_ sampleBuffer: CMSampleBuffer, source: AudioSource) throws {
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
        isFinishing = true

        if !hasStartedSession, !pendingSamples.isEmpty {
            try beginSession()
        }

        guard hasStartedSession else {
            writer.cancelWriting()
            throw AudioWriterError.noAudio
        }

        systemInput.markAsFinished()
        microphoneInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? AudioWriterError.finishFailed
        }
        return outputURL
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
        guard tracks.count >= 2 else {
            throw AudioWriterError.missingTrack
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(index == 0 ? 0.5 : 1.0, at: .zero)
            return parameters
        }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioWriterError.exportUnavailable
        }
        exporter.audioMix = mix
        try await exporter.export(to: destinationURL, as: .m4a)
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

private enum AudioWriterError: LocalizedError {
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
