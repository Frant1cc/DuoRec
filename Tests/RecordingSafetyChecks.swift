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

func writeAudio(_ writer: DualTrackAudioWriter, count: Int, microphone: Bool = true) async throws {
    for index in 0..<count {
        try writer.append(sample(index: index, channels: 2), source: .system)
        if microphone { try writer.append(sample(index: index, channels: 1), source: .microphone) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@main struct RecordingSafetyChecks {
    static func main() async throws {
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
        let mixed = root.appendingPathComponent("normal.m4a")
        let writer = try DualTrackAudioWriter(outputURL: raw)
        try await writeAudio(writer, count: 200)
        // A stream already stopped by the OS still has to seal its writer.
        let finished = try await RecordingFinalizer.finish(
            stopping: { throw ExpectedFailure.stopped },
            finishing: { try await writer.finish() }
        )
        precondition(finished == raw)
        try await assertDecodable(raw, minimumDuration: 1.9, tracks: 2)
        try await AudioMixer.mixTracks(in: raw, to: mixed)
        try await assertDecodable(mixed, minimumDuration: 1.9)
        print("PASS: stop failure still saves decodable two-track audio and M4A")

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
        let singleMixed = root.appendingPathComponent("single.m4a")
        try await AudioMixer.mixTracks(in: singleRaw, to: singleMixed)
        try await assertDecodable(singleMixed, minimumDuration: 0.8)
        print("PASS: one available audio source is preserved")

        let crashRaw = root.appendingPathComponent("crash.mov")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash-write", crashRaw.path]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let recovered = root.appendingPathComponent("recovered.m4a")
        try await AudioMixer.mixTracks(in: crashRaw, to: recovered)
        try await assertDecodable(recovered, minimumDuration: 5)
        let recoveredDuration = try await AVURLAsset(url: recovered).load(.duration).seconds
        print("PASS: SIGKILL recovery decoded \(recoveredDuration)s of 12s synthetic recording")
        print("All recording safety checks passed")
    }
}
