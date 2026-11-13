import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class TranscriptionModel: ObservableObject {
    enum Phase {
        case idle
        case preparing
        case transcribing
        case finished
        case failed
    }

    @Published var text = ""
    @Published var filter: TranscriptFilter = .all
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var usesSourceTimeline = false
    @Published private(set) var fileName: String?
    @Published private(set) var phase: Phase = .idle
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    let models: WhisperModelStore
    private let engine: any WhisperRecognizing
    private var cancellation = WhisperCancellation()
    private var activeModel: WhisperModel?
    private var trackID = UUID()
    @Published private(set) var progress: Double = 0
    @Published private(set) var runningModelName: String?
    @Published private(set) var documentID = UUID()
    private let sourceResolver: (URL) async throws -> URL?
    private let trackExtractor: (URL, URL) async throws -> [AudioTrackExtractor.Track]

    init(models: WhisperModelStore? = nil,
         engine: (any WhisperRecognizing)? = nil,
         sourceResolver: @escaping (URL) async throws -> URL? = AudioTrackExtractor.transcriptionSourceURL,
         trackExtractor: @escaping (URL, URL) async throws -> [AudioTrackExtractor.Track] = AudioTrackExtractor.extractTracks) {
        self.models = models ?? WhisperModelStore()
        self.engine = engine ?? WhisperTranscriber()
        self.sourceResolver = sourceResolver
        self.trackExtractor = trackExtractor
    }

    var isWorking: Bool { phase == .preparing || phase == .transcribing }

    func chooseFile(outputFolderURL: URL) {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "transcription.file_picker.title")
        panel.prompt = String(localized: "transcription.file_picker.choose")
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url, !isWorking else { return }
        transcribe(url: url, outputFolderURL: outputFolderURL)
    }

    func cancel() {
        documentID = UUID()
        task?.cancel()
        task = nil
        cancellation.cancel()
        progress = 0
        runningModelName = nil
        phase = .idle
        text = ""
        filter = .all
        segments = []
        usesSourceTimeline = false
        fileName = nil
        errorMessage = nil
    }

    @discardableResult
    func transcribe(url: URL, outputFolderURL: URL) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        cancel()
        let currentGeneration = UUID()
        documentID = currentGeneration
        fileName = url.lastPathComponent
        phase = .preparing
        cancellation = WhisperCancellation()
        let runCancellation = cancellation
        activeModel = models.transcriptionModel
        runningModelName = activeModel?.rawValue

        let task = Task {
            defer { runCancellation.cancel() }
            let hasFileScope = url.startAccessingSecurityScopedResource()
            let isSavedRecording = url.deletingLastPathComponent().standardizedFileURL == outputFolderURL.standardizedFileURL
            let hasFolderScope = isSavedRecording && outputFolderURL.startAccessingSecurityScopedResource()
            defer {
                if hasFileScope { url.stopAccessingSecurityScopedResource() }
                if hasFolderScope { outputFolderURL.stopAccessingSecurityScopedResource() }
            }

            do {
                try requireCurrentGeneration(currentGeneration)
                if let dualTrackURL = try await sourceResolver(url) {
                    try requireCurrentGeneration(currentGeneration)
                    usesSourceTimeline = true
                    try await transcribeDualTrackFile(dualTrackURL, generation: currentGeneration)
                } else {
                    _ = try await transcribeAudioFile(
                        url, source: nil, timeOffset: 0, firstMediaTime: 0, generation: currentGeneration
                    )
                }
                guard documentID == currentGeneration, !Task.isCancelled else { return }
                progress = 1
                phase = .finished
                let hasSpeech = usesSourceTimeline ? !segments.isEmpty : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !hasSpeech { errorMessage = String(localized: "transcription.error.no_speech") }
            } catch {
                guard documentID == currentGeneration, !Task.isCancelled else { return }
                phase = .failed
                errorMessage = error.localizedDescription
            }

            guard documentID == currentGeneration else { return }
            self.task = nil
        }
        self.task = task
        return task
    }

    private func transcribeDualTrackFile(_ url: URL, generation currentGeneration: UUID) async throws {
        try requireCurrentGeneration(currentGeneration)
        let temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuoRec-Transcription-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryFolder) }

        let tracks = try await trackExtractor(url, temporaryFolder)
        try requireCurrentGeneration(currentGeneration)
        guard !tracks.isEmpty else { throw WhisperError.unreadableAudio }
        let totalDuration = tracks.reduce(0) { $0 + $1.duration }
        guard totalDuration.isFinite, totalDuration > 0,
              tracks.allSatisfy({ $0.duration.isFinite && $0.duration > 0 }) else {
            throw WhisperError.unreadableAudio
        }
        var completedDuration = 0.0
        for track in tracks {
            try requireCurrentGeneration(currentGeneration)
            _ = try await transcribeAudioFile(
                track.url,
                source: track.source,
                timeOffset: track.startTime,
                firstMediaTime: track.firstMediaTime,
                generation: currentGeneration,
                progressStart: completedDuration / totalDuration,
                progressWeight: track.duration / totalDuration
            )
            completedDuration += track.duration
        }
    }

    private func transcribeAudioFile(
        _ url: URL,
        source: AudioSource?,
        timeOffset: TimeInterval,
        firstMediaTime: TimeInterval,
        generation currentGeneration: UUID,
        progressStart: Double = 0,
        progressWeight: Double = 1
    ) async throws -> [TranscriptSegment] {
        try requireCurrentGeneration(currentGeneration)
        guard let activeModel, models.installed.contains(activeModel) else { throw WhisperError.modelMissing }
        let modelURL = models.modelURL(for: activeModel)
        let currentTrackID = UUID()
        trackID = currentTrackID
        phase = .transcribing
        progress = max(progress, progressStart)
        let pieces = try await engine.transcribe(
            url: url, modelURL: modelURL, cancellation: cancellation
        ) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.documentID == currentGeneration,
                      self.trackID == currentTrackID, self.isWorking else { return }
                guard value.isFinite else { return }
                let combined = progressStart + progressWeight * max(0, min(1, value))
                self.progress = max(self.progress, min(1, combined))
            }
        }
        try requireCurrentGeneration(currentGeneration)
        let collected = pieces.map { piece in
            let start = max(firstMediaTime, piece.start + timeOffset)
            return TranscriptSegment(source: source, startTime: start,
                                     endTime: max(start, piece.end + timeOffset), text: piece.text)
        }
        if source != nil {
            segments.append(contentsOf: collected)
            segments.sort { $0.startTime < $1.startTime }
        } else {
            text = collected.map(\.text).joined()
        }
        progress = max(progress, min(1, progressStart + progressWeight))
        return collected
    }

    private func requireCurrentGeneration(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard documentID == expected else { throw CancellationError() }
    }
}
