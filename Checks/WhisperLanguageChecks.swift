import AVFoundation
import Foundation

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        precondition(value >= (values.last ?? 0) && value <= 1, "Progress went backwards across chunks")
        values.append(value)
    }

    func checkFinished() {
        lock.lock()
        defer { lock.unlock() }
        precondition(values.last == 1)
    }
}

// Opt-in integration check: uses installed macOS voices and a real multilingual
// small model supplied by the developer. Does not download models or use a mic.
@main
struct WhisperLanguageChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: whisper-language-checks /path/to/ggml-small.bin")
        }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        try await WhisperModelFiles.verify(modelURL, model: .small)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DuoRec-Languages-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = [
            ("english", "Samantha", "Hello everyone. The meeting starts at nine tomorrow morning. Please bring your notes."),
            ("chinese", "Tingting", "大家好，明天上午九点开会。请大家提前准备好会议材料，我们一起讨论新的工作计划。"),
            ("japanese", "Kyoko", "こんにちは。明日の会議は午前九時に始まります。新しい仕事の計画について話しましょう。")
        ]
        var urls: [URL] = []
        for (name, voice, text) in fixtures {
            let url = root.appendingPathComponent("\(name).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", url.path, text]
            try say.run()
            say.waitUntilExit()
            precondition(say.terminationStatus == 0, "Install the \(voice) macOS voice to run this check")
            urls.append(url)
        }
        let engine = WhisperTranscriber()
        for (index, url) in urls.enumerated() {
            let pieces = try await recognize(url, model: modelURL, engine: engine)
            let text = pieces.map(\.text).joined()
            log("TRANSCRIPT \(fixtures[index].0): \(text)")
            switch index {
            case 0: precondition(text.lowercased().contains("meeting"))
            case 1:
                precondition(containsChinese(text) && !text.lowercased().contains("meeting"))
                checkSimplifiedChinese(text)
            default: precondition(containsKana(text))
            }
        }

        // Both orders, with multiple languages in a single ordinary audio track.
        // The longer fixture also switches language beyond Whisper's first window.
        for (name, order) in [("en-zh-ja", [0, 0, 0, 0, 0, 1, 2]), ("zh-en", [1, 0])] {
            let url = root.appendingPathComponent("\(name).m4a")
            let starts = try await concatenate(order.map { urls[$0] }, to: url)
            let pieces = try await recognize(url, model: modelURL, engine: engine)
            let text = pieces.map(\.text).joined()
            log("TRANSCRIPT \(name): \(text)")
            for piece in pieces { log("TIMESTAMP \(piece.start)...\(piece.end): \(piece.text)") }
            precondition(text.lowercased().contains("meeting") && containsChinese(text))
            // Inspect Chinese pieces only: Japanese kanji must retain their form.
            for piece in pieces where containsChinese(piece.text) && !containsKana(piece.text) {
                checkSimplifiedChinese(piece.text)
            }
            if name == "en-zh-ja" {
                precondition(starts[5] > 30 && containsKana(text))
                // Whisper can timestamp the preceding pause as part of a
                // phrase. Allow that 1.2 s gap plus normal model imprecision.
                precondition(pieces.contains { $0.start >= starts[5] - 2 && $0.end > starts[5] && containsChinese($0.text) },
                             "Chinese speech after 30 seconds was translated or lost its track timestamp")
                precondition(pieces.contains { $0.start >= starts[6] - 2 && $0.end > starts[6] && containsKana($0.text) })
            }
        }
        let cancellation = WhisperCancellation()
        do {
            _ = try await engine.transcribe(url: urls[0], modelURL: modelURL, cancellation: cancellation) { _ in
                cancellation.cancel()
            }
            preconditionFailure("Native inference ignored cancellation")
        } catch is CancellationError { }
        log("PASS: real small model, Simplified Chinese/English/Japanese, mixed-language tracks in both orders, timestamps, progress and native cancellation")
    }

    private static func recognize(_ url: URL, model: URL, engine: WhisperTranscriber) async throws -> [WhisperPiece] {
        let progress = ProgressProbe()
        let pieces = try await engine.transcribe(url: url, modelURL: model, cancellation: WhisperCancellation()) {
            progress.record($0)
        }
        progress.checkFinished()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        precondition(!pieces.isEmpty)
        var lastStart = 0.0
        for piece in pieces {
            precondition(piece.start >= lastStart && piece.end >= piece.start && piece.end <= duration + 0.05)
            lastStart = piece.start
        }
        return pieces
    }

    private static func concatenate(_ urls: [URL], to destination: URL) async throws -> [Double] {
        let composition = AVMutableComposition()
        let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        var cursor = CMTime.zero
        var starts: [Double] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let source = try await asset.loadTracks(withMediaType: .audio)[0]
            let duration = try await asset.load(.duration)
            starts.append(cursor.seconds)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = CMTimeAdd(CMTimeAdd(cursor, duration), CMTime(seconds: 1.2, preferredTimescale: 16_000))
        }
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)!
        try await exporter.export(to: destination, as: .m4a)
        return starts
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func checkSimplifiedChinese(_ text: String) {
        let traditionalCharacters = CharacterSet(charactersIn: "點開會請準備議與計畫討論們")
        precondition(text.rangeOfCharacter(from: traditionalCharacters) == nil,
                     "Chinese transcription still contains Traditional Chinese: \(text)")
    }

    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }

    private static func log(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
