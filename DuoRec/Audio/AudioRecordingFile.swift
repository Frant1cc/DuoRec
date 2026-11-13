@preconcurrency import AVFoundation
import CoreMedia

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
