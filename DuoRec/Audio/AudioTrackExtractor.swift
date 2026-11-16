@preconcurrency import AVFoundation
import CoreMedia

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
        let duration: TimeInterval
    }

    nonisolated static func companionURL(for mixedRecordingURL: URL) -> URL {
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
                    firstMediaTime: firstMediaTime,
                    duration: timeRange.duration.seconds
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
