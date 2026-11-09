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

enum AudioRecordingFile {
    static func save(_ sourceURL: URL, to destinationURL: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        // Keep incomplete exports outside the save folder, and retain the
        // recoverable capture until every track has been written successfully.
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuoRec-Export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try await MP4RecordingExporter.export(sourceURL, to: stagingURL)
        try await preserve(stagingURL, to: destinationURL)
        do {
            try FileManager.default.removeItem(at: sourceURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    static func preserve(_ sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        guard !tracks.isEmpty, duration.isNumeric, duration.seconds > 0 else {
            throw AudioWriterError.noAudio
        }
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch let moveError {
            // Cross-volume saves must complete the copy before removing the
            // recoverable source. Never replace an existing recording.
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else { throw moveError }
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                try FileManager.default.removeItem(at: sourceURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }
    }
}

private enum MP4RecordingExporter {
    static func export(_ sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        guard !tracks.isEmpty, duration.isNumeric, duration.seconds > 0 else { throw AudioWriterError.noAudio }
        let sources = try await AudioTrackExtractor.sourceTracks(in: sourceURL, asset: asset, inferLegacySources: true)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // The first/default track contains the full mix, so players that only
        // play one audio track still present both voices.
        let mixedInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ])
        mixedInput.metadata = metadata(label: "duorec.mix")
        guard writer.canAdd(mixedInput) else { throw AudioWriterError.cannotAddInputs }
        writer.add(mixedInput)
        let mixReader = try AVAssetReader(asset: asset)
        let playbackTracks = sources.isEmpty ? tracks : sources.map(\.track)
        let mixedOutput = AVAssetReaderAudioMixOutput(audioTracks: playbackTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false
        ])
        let mix = AVMutableAudioMix()
        mix.inputParameters = playbackTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let isSystem = sources.contains { $0.track.trackID == track.trackID && $0.source == .system }
            parameters.setVolume(sources.count > 1 && isSystem ? 0.5 : 1, at: .zero)
            return parameters
        }
        mixedOutput.audioMix = mix
        guard mixReader.canAdd(mixedOutput) else { throw AudioWriterError.exportUnavailable }
        mixReader.add(mixedOutput)

        var inputs = [mixedInput]
        var outputs: [AVAssetReaderOutput] = [mixedOutput]
        var readers = [mixReader]
        for source in sources {
            let formats = try await source.track.load(.formatDescriptions)
            guard let format = formats.first else { throw AudioWriterError.missingTrack }
            // Copy the original AAC packets, preserving each source's quality
            // and timestamps. Only the playback mix is newly encoded.
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.metadata = metadata(label: source.source == .system ? "duorec.system" : "duorec.microphone")
            guard writer.canAdd(input) else { throw AudioWriterError.cannotAddInputs }
            writer.add(input)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: nil)
            guard reader.canAdd(output) else { throw AudioWriterError.exportUnavailable }
            reader.add(output)
            inputs.append(input)
            outputs.append(output)
            readers.append(reader)
        }
        if inputs.count > 1 {
            let group = AVAssetWriterInputGroup(inputs: inputs, defaultInput: mixedInput)
            guard writer.canAdd(group) else { throw AudioWriterError.cannotAddInputs }
            writer.add(group)
        }
        do {
            guard writer.startWriting() else { throw writer.error ?? AudioWriterError.startFailed }
            writer.startSession(atSourceTime: .zero)
            for reader in readers {
                guard reader.startReading() else { throw reader.error ?? AudioWriterError.exportUnavailable }
            }
            try await transfer(inputs: inputs, outputs: outputs, readers: readers, writer: writer)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? AudioWriterError.finishFailed }
            let savedAsset = AVURLAsset(url: destinationURL)
            let savedTracks = try await savedAsset.loadTracks(withMediaType: .audio)
            let savedSources = try await AudioTrackExtractor.sourceTracks(in: destinationURL, asset: savedAsset)
            guard savedTracks.count == sources.count + 1,
                  savedSources.map(\.source) == sources.map(\.source) else { throw AudioWriterError.missingTrack }
        } catch {
            readers.filter { $0.status == .reading }.forEach { $0.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    private static func metadata(label: String) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        // MP4 discards QuickTime metadata comments; use its ISO user-data title.
        item.identifier = .identifier3GPUserDataTitle
        item.value = label as NSString
        item.extendedLanguageTag = "und"
        return [item]
    }

    static func extract(_ track: AVAssetTrack, in asset: AVAsset, to destinationURL: URL) async throws {
        let range = try await track.load(.timeRange)
        let formats = try await track.load(.formatDescriptions)
        let channelCount = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
        let channels = min(max(Int(channelCount), 1), 2)
        // Read the chosen track explicitly. A normal export session may omit it
        // because MP4 source tracks are intentionally disabled for playback.
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw AudioWriterError.exportUnavailable }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 64_000 : 128_000
        ])
        guard writer.canAdd(input) else { throw AudioWriterError.cannotAddInputs }
        writer.add(input)
        do {
            guard writer.startWriting() else { throw writer.error ?? AudioWriterError.startFailed }
            writer.startSession(atSourceTime: range.start)
            guard reader.startReading() else { throw reader.error ?? AudioWriterError.exportUnavailable }
            try await transfer(inputs: [input], outputs: [output], readers: [reader], writer: writer)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? AudioWriterError.finishFailed }
        } catch {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    @concurrent private static func transfer(
        inputs: [AVAssetWriterInput], outputs: [AVAssetReaderOutput],
        readers: [AVAssetReader], writer: AVAssetWriter
    ) async throws {
        var finished = Set<Int>()
        while finished.count < inputs.count {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? AudioWriterError.appendFailed }
            var advanced = false
            for index in inputs.indices where !finished.contains(index) {
                guard inputs[index].isReadyForMoreMediaData else { continue }
                if let buffer = outputs[index].copyNextSampleBuffer() {
                    // Fragmented captures can include timing-only markers;
                    // MP4 inputs accept the media packets, not those markers.
                    if CMSampleBufferGetNumSamples(buffer) == 0 || CMSampleBufferGetDataBuffer(buffer) == nil {
                        advanced = true
                        continue
                    }
                    guard inputs[index].append(buffer) else { throw writer.error ?? AudioWriterError.appendFailed }
                } else {
                    guard readers[index].status == .completed else {
                        throw readers[index].error ?? AudioWriterError.finishFailed
                    }
                    inputs[index].markAsFinished()
                    finished.insert(index)
                }
                advanced = true
            }
            if !advanced { try await Task.sleep(for: .milliseconds(2)) }
        }
    }
}

// DualTrackAudioWriter adds system audio first and microphone audio second.
// Exporting one track at a time keeps the speech recognizer from hearing the
// other source. MP4 also carries a default mixed track, which must be excluded.
enum AudioTrackExtractor {
    struct SourceTrack {
        let source: AudioSource
        let track: AVAssetTrack
    }
    struct Track {
        let source: AudioSource
        let url: URL
        let startTime: TimeInterval
        let firstMediaTime: TimeInterval
    }

    static func companionURL(for mixedRecordingURL: URL) -> URL {
        mixedRecordingURL.deletingPathExtension().appendingPathExtension("tracks.mov")
    }

    static func transcriptionSourceURL(for recordingURL: URL) async throws -> URL? {
        if try await !sourceTracks(in: recordingURL).isEmpty { return recordingURL }
        // Older recordings used a mixed M4A and a separate source file.
        if recordingURL.lastPathComponent.hasSuffix(".tracks.mov") { return recordingURL }
        let companion = companionURL(for: recordingURL)
        if recordingURL.pathExtension.lowercased() == "m4a",
           FileManager.default.fileExists(atPath: companion.path) {
            return companion
        }
        return nil
    }

    static func sourceTracks(in sourceURL: URL, asset: AVAsset? = nil, inferLegacySources: Bool = false) async throws -> [SourceTrack] {
        let tracks = try await (asset ?? AVURLAsset(url: sourceURL)).loadTracks(withMediaType: .audio)
        var sources: [SourceTrack] = []
        for track in tracks {
            if let source = try await labeledSource(for: track) {
                sources.append(SourceTrack(source: source, track: track))
            }
        }
        if !sources.isEmpty { return sources }
        // Old dual-track MOV files predate source metadata. Never infer sources
        // from the track order of an ordinary MP4 or M4A.
        if sourceURL.pathExtension.lowercased() == "mov",
           inferLegacySources || sourceURL.lastPathComponent.hasSuffix(".tracks.mov") {
            return tracks.prefix(2).enumerated().map {
                SourceTrack(source: $0.offset == 0 ? .system : .microphone, track: $0.element)
            }
        }
        return []
    }

    static func extractTracks(in sourceURL: URL, to directoryURL: URL) async throws -> [Track] {
        let asset = AVURLAsset(url: sourceURL)
        let sources = try await sourceTracks(in: sourceURL, asset: asset)
        guard !sources.isEmpty else { throw AudioWriterError.missingTrack }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var extracted: [Track] = []
        do {
            for (index, sourceTrack) in sources.enumerated() {
                let track = sourceTrack.track
                let timeRange = try await track.load(.timeRange)
                guard timeRange.duration.isNumeric, timeRange.duration.seconds > 0 else { continue }
                let segments = try await track.load(.segments)
                let firstMediaTime = segments.first(where: { !$0.isEmpty })?
                    .timeMapping.target.start.seconds ?? timeRange.start.seconds
                let source = sourceTrack.source
                let destination = directoryURL.appendingPathComponent("track-\(index).m4a")
                do {
                    try await MP4RecordingExporter.extract(track, in: asset, to: destination)
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

    private static func labeledSource(for track: AVAssetTrack) async throws -> AudioSource? {
        let metadata = try await track.load(.metadata)
        let identifiers: Set<AVMetadataIdentifier> = [.quickTimeMetadataComment, .identifier3GPUserDataTitle]
        for item in metadata where item.identifier.map(identifiers.contains) == true {
            switch try await item.load(.stringValue) {
            case "duorec.system": return .system
            case "duorec.microphone": return .microphone
            default: continue
            }
        }
        return nil
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
