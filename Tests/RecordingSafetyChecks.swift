import Foundation
import AVFoundation
import CoreMedia

func sample(index: Int, channels: Int) throws -> CMSampleBuffer {
    let frames = 480
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
    let values = (0..<(frames * channels)).map { i in Float(sin(Double(index * frames + i / channels) * 2 * .pi * (channels == 1 ? 880 : 440) / 48_000)) * 0.1 }
    var block: CMBlockBuffer?
    precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: values.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: values.count * 4, flags: 0, blockBufferOut: &block) == noErr)
    values.withUnsafeBytes { bytes in
        precondition(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) == noErr)
    }
    var buffer: CMSampleBuffer?
    precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format!, sampleCount: frames, presentationTimeStamp: CMTime(value: Int64(index * frames), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &buffer) == noErr)
    return buffer!
}

enum ExpectedFailure: Error { case stopped, finishFailed }

func assertDecodable(_ url: URL, minimumDuration: Double, tracks expectedTracks: Int = 1) async throws {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    precondition(tracks.count == expectedTracks, "Unexpected track count")
    let duration = try await asset.load(.duration).seconds
    precondition(duration >= minimumDuration, "Recording too short: \(duration)")
    for track in tracks {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32
        ])
        reader.add(output)
        precondition(reader.startReading())
        var decodedFrames = 0
        while let buffer = output.copyNextSampleBuffer() {
            decodedFrames += CMSampleBufferGetNumSamples(buffer)
        }
        precondition(reader.status == .completed, "Audio cannot be decoded")
        precondition(decodedFrames >= Int(minimumDuration * 48_000), "Missing decoded audio")
    }
}

func writeAudio(_ writer: DualTrackAudioWriter, count: Int, microphone: Bool = true, system: Bool = true, microphoneStartIndex: Int = 0) async throws {
    for index in 0..<count {
        if system { try writer.append(sample(index: index, channels: 2), source: .system) }
        if microphone && index >= microphoneStartIndex { try writer.append(sample(index: index, channels: 1), source: .microphone) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

func toneAmplitudes(in url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    var tracks: [AVAssetTrack] = []
    for track in try await asset.loadTracks(withMediaType: .audio) {
        if try await track.load(.isEnabled) { tracks.append(track) }
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsNonInterleaved: false
    ])
    reader.add(output)
    precondition(reader.startReading())
    var frameCount = 0
    var sine = [0.0, 0.0]
    var cosine = [0.0, 0.0]
    while let buffer = output.copyNextSampleBuffer() {
        let block = CMSampleBufferGetDataBuffer(buffer)!
        let byteCount = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: byteCount / 4)
        let status = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
        }
        precondition(status == noErr)
        for frame in 0..<CMSampleBufferGetNumSamples(buffer) {
            for (index, frequency) in [440.0, 880.0].enumerated() {
                let phase = Double(frameCount) * 2 * .pi * frequency / 48_000
                sine[index] += Double(samples[frame * 2]) * sin(phase)
                cosine[index] += Double(samples[frame * 2]) * cos(phase)
            }
            frameCount += 1
        }
    }
    precondition(reader.status == .completed && frameCount > 0)
    return (0..<2).map { 2 * hypot(sine[$0], cosine[$0]) / Double(frameCount) }
}

@MainActor func assertDefaultPlayback(_ url: URL, expectedTracks: Int) async throws {
    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    player.volume = 0
    player.play()
    defer { player.pause() }
    for _ in 0..<100 {
        if item.status != .unknown { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    precondition(item.status == .readyToPlay, "Recording is not playable")
    precondition(item.tracks.count == expectedTracks)
    precondition(item.tracks.first?.isEnabled == true, "Mixed track must be the default")
    precondition(item.tracks.filter(\.isEnabled).count == 1, "Source tracks must not play over the mix")
}

func compressedAudio(in url: URL) async throws -> [Data] {
    let asset = AVURLAsset(url: url)
    var result: [Data] = []
    for track in try await asset.loadTracks(withMediaType: .audio) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        precondition(reader.startReading())
        var data = Data()
        while let sample = output.copyNextSampleBuffer() {
            // Compressed readers can also return timing-only marker buffers.
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            precondition(status == noErr)
            data.append(contentsOf: bytes)
        }
        precondition(reader.status == .completed)
        result.append(data)
    }
    return result
}

@main struct RecordingSafetyChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--crash-write" {
            let writer = try DualTrackAudioWriter(outputURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            try await writeAudio(writer, count: 1_200)
            // End only this synthetic-test child. No finishWriting or deinit runs.
            kill(getpid(), SIGKILL)
            fatalError("SIGKILL should not return")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent("safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("normal.mov")
        let savedFolder = root.appendingPathComponent("saved", isDirectory: true)
        try FileManager.default.createDirectory(at: savedFolder, withIntermediateDirectories: true)
        let saved = savedFolder.appendingPathComponent("normal.mp4")
        let writer = try DualTrackAudioWriter(outputURL: raw)
        try await writeAudio(writer, count: 200)
        // A stream already stopped by the OS still has to seal its writer.
        let finished = try await RecordingFinalizer.finish(
            stopping: { throw ExpectedFailure.stopped },
            finishing: { try await writer.finish() }
        )
        precondition(finished == raw)
        let originalPackets = try await compressedAudio(in: raw)
        let legacyCompanion = root.appendingPathComponent("legacy.tracks.mov")
        try FileManager.default.copyItem(at: raw, to: legacyCompanion)
        try await AudioRecordingFile.save(raw, to: saved)
        precondition(!FileManager.default.fileExists(atPath: raw.path))
        let savedFiles = try FileManager.default.contentsOfDirectory(at: savedFolder, includingPropertiesForKeys: nil)
        precondition(savedFiles == [saved], "Saving should create exactly one file")
        try await assertDecodable(saved, minimumDuration: 1.9, tracks: 3)
        try await assertDefaultPlayback(saved, expectedTracks: 3)
        let savedPackets = try await compressedAudio(in: saved)
        precondition(Array(savedPackets.dropFirst()) == originalPackets, "Source AAC must be copied without re-encoding")
        let amplitudes = try await toneAmplitudes(in: saved)
        precondition(amplitudes.allSatisfy { $0 > 0.03 }, "Mixed playback is missing a source")
        let detectedSource = try await AudioTrackExtractor.transcriptionSourceURL(for: saved)
        precondition(detectedSource == saved, "Single-file recording was not recognized")
        let originalTracks = try await AVURLAsset(url: saved).loadTracks(withMediaType: .audio)
        let sourceLabels = try await originalTracks.asyncMap { track in
            let items = try await track.load(.metadata)
            let comment = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .identifier3GPUserDataTitle).first
            return try await comment?.load(.stringValue)
        }
        precondition(sourceLabels == ["duorec.mix", "duorec.system", "duorec.microphone"])
        let separated = try await AudioTrackExtractor.extractTracks(
            in: saved,
            to: root.appendingPathComponent("separated")
        )
        precondition(separated.count == 2)
        precondition(separated[0].source == .system && separated[1].source == .microphone)
        for (index, track) in separated.enumerated() {
            try await assertDecodable(track.url, minimumDuration: 1.9)
            let tones = try await toneAmplitudes(in: track.url)
            precondition(tones[index] > 0.03 && tones[1 - index] < 0.005, "Transcription sources are not isolated")
        }
        print("PASS: one saved file plays both sources and isolates labeled transcription tracks")

        // A renamed MP4 still uses embedded labels; old M4A pairs remain usable.
        let renamed = savedFolder.appendingPathComponent("renamed.mp4")
        try FileManager.default.moveItem(at: saved, to: renamed)
        let renamedSource = try await AudioTrackExtractor.transcriptionSourceURL(for: renamed)
        precondition(renamedSource == renamed)
        let legacyM4A = root.appendingPathComponent("legacy.m4a")
        try FileManager.default.copyItem(at: separated[0].url, to: legacyM4A)
        let ordinaryM4A = root.appendingPathComponent("ordinary.m4a")
        try FileManager.default.copyItem(at: separated[0].url, to: ordinaryM4A)
        let ordinarySource = try await AudioTrackExtractor.transcriptionSourceURL(for: ordinaryM4A)
        precondition(ordinarySource == nil, "Ordinary audio must not receive invented source labels")
        let ordinaryMP4 = root.appendingPathComponent("ordinary.mp4")
        try await AudioRecordingFile.save(ordinaryM4A, to: ordinaryMP4)
        try await assertDecodable(ordinaryMP4, minimumDuration: 1.9)
        let ordinaryMP4Source = try await AudioTrackExtractor.transcriptionSourceURL(for: ordinaryMP4)
        precondition(ordinaryMP4Source == nil)
        let legacySource = try await AudioTrackExtractor.transcriptionSourceURL(for: legacyM4A)
        precondition(legacySource == legacyCompanion)
        do {
            try await AudioRecordingFile.save(legacyCompanion, to: renamed)
            fatalError("An existing recording was overwritten")
        } catch { precondition(FileManager.default.fileExists(atPath: legacyCompanion.path)) }
        let unavailableDestination = root.appendingPathComponent("missing-folder/recording.mp4")
        do {
            try await AudioRecordingFile.save(legacyCompanion, to: unavailableDestination)
            fatalError("An unavailable destination reported success")
        } catch {
            precondition(FileManager.default.fileExists(atPath: legacyCompanion.path), "Save failure discarded the recoverable source")
            precondition(!FileManager.default.fileExists(atPath: unavailableDestination.path))
        }
        print("PASS: renaming, legacy pairs, ordinary audio recovery, and save collisions are safe")

        // Repeated finish calls must share one operation, including after completion.
        let concurrent = try DualTrackAudioWriter(outputURL: root.appendingPathComponent("concurrent.mov"))
        try await writeAudio(concurrent, count: 100)
        async let first = concurrent.finish()
        async let second = concurrent.finish()
        let urls = try await (first, second)
        precondition(urls.0 == urls.1)
        try concurrent.append(sample(index: 100, channels: 2), source: .system)
        let repeated = try await concurrent.finish()
        precondition(repeated == urls.0)
        try await assertDecodable(repeated, minimumDuration: 0.9, tracks: 2)
        print("PASS: concurrent/repeated finish and late callback are safe")

        var finishAttempted = false
        do {
            _ = try await RecordingFinalizer.finish(
                stopping: { throw ExpectedFailure.stopped },
                finishing: { finishAttempted = true; throw ExpectedFailure.finishFailed }
            )
            fatalError("Save failure was hidden")
        } catch ExpectedFailure.finishFailed { precondition(finishAttempted) }
        let empty = try DualTrackAudioWriter(outputURL: root.appendingPathComponent("empty.mov"))
        for _ in 0..<2 {
            do { _ = try await empty.finish(); fatalError("Empty recording reported as saved") }
            catch AudioWriterError.noAudio {}
        }
        print("PASS: save errors and empty audio are reported, repeated failure does not hang")

        let singleRaw = root.appendingPathComponent("single.mov")
        let single = try DualTrackAudioWriter(outputURL: singleRaw)
        try await writeAudio(single, count: 100, microphone: false)
        _ = try await single.finish()
        let singleSaved = root.appendingPathComponent("single-saved.mp4")
        try await AudioRecordingFile.save(singleRaw, to: singleSaved)
        try await assertDecodable(singleSaved, minimumDuration: 0.8, tracks: 2)
        try await assertDefaultPlayback(singleSaved, expectedTracks: 2)
        let singleSource = try await AudioTrackExtractor.transcriptionSourceURL(for: singleSaved)
        precondition(singleSource == singleSaved)
        let microphoneRaw = root.appendingPathComponent("microphone.mov")
        let microphone = try DualTrackAudioWriter(outputURL: microphoneRaw)
        try await writeAudio(microphone, count: 100, system: false)
        _ = try await microphone.finish()
        let microphoneSaved = root.appendingPathComponent("microphone.mp4")
        try await AudioRecordingFile.save(microphoneRaw, to: microphoneSaved)
        try await assertDecodable(microphoneSaved, minimumDuration: 0.8, tracks: 2)
        let microphoneSources = try await AudioTrackExtractor.sourceTracks(in: microphoneSaved)
        precondition(microphoneSources.map(\.source) == [.microphone], "Microphone-only audio was mislabeled")
        print("PASS: either available source is preserved with its correct label")

        let delayedRaw = root.appendingPathComponent("delayed.mov")
        let delayed = try DualTrackAudioWriter(outputURL: delayedRaw)
        try await writeAudio(delayed, count: 150, microphoneStartIndex: 50)
        _ = try await delayed.finish()
        let before = try await AudioTrackExtractor.extractTracks(in: delayedRaw, to: root.appendingPathComponent("before"))
        let delayedSaved = root.appendingPathComponent("delayed.mp4")
        try await AudioRecordingFile.save(delayedRaw, to: delayedSaved)
        let after = try await AudioTrackExtractor.extractTracks(in: delayedSaved, to: root.appendingPathComponent("after"))
        precondition(before.count == after.count && after.count == 2)
        for (original, saved) in zip(before, after) {
            precondition(original.source == saved.source)
            precondition(abs(original.startTime - saved.startTime) < 0.001)
            precondition(abs(original.firstMediaTime - saved.firstMediaTime) < 0.001, "MP4 shifted the source timeline")
        }
        print("PASS: late-starting source timestamps survive MP4 remuxing")

        let crashRaw = root.appendingPathComponent("crash.mov")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash-write", crashRaw.path]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let recovered = root.appendingPathComponent("recovered.mp4")
        try await AudioRecordingFile.save(crashRaw, to: recovered)
        try await assertDecodable(recovered, minimumDuration: 5, tracks: 3)
        try await assertDefaultPlayback(recovered, expectedTracks: 3)
        let recoveredDuration = try await AVURLAsset(url: recovered).load(.duration).seconds
        print("PASS: SIGKILL recovery decoded \(recoveredDuration)s of 12s synthetic recording")
        print("All recording safety checks passed")
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
