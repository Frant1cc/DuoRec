@preconcurrency import AVFoundation
import CoreMedia

enum MP4RecordingExporter {
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
