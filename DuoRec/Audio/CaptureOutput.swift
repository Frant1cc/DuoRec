@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

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
