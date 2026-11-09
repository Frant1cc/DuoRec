import AppKit
import AVFoundation
import Combine
import SwiftUI
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
    private var activeModel: WhisperModel = .largeV3Turbo
    private var activeLanguage: WhisperLanguage = .automatic
    private var trackID = UUID()
    @Published private(set) var progress: Double = 0
    @Published private(set) var runningModelName: String?
    @Published private(set) var documentID = UUID()
    private let sourceResolver: (URL) async throws -> URL?

    init(models: WhisperModelStore? = nil,
         engine: (any WhisperRecognizing)? = nil,
         sourceResolver: @escaping (URL) async throws -> URL? = AudioTrackExtractor.transcriptionSourceURL) {
        self.models = models ?? WhisperModelStore()
        self.engine = engine ?? WhisperTranscriber()
        self.sourceResolver = sourceResolver
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
        activeModel = models.selectedModel
        activeLanguage = models.language
        runningModelName = activeModel.rawValue

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

        let tracks = try await AudioTrackExtractor.extractTracks(in: url, to: temporaryFolder)
        try requireCurrentGeneration(currentGeneration)
        guard !tracks.isEmpty else { throw WhisperError.unreadableAudio }
        for track in tracks {
            try requireCurrentGeneration(currentGeneration)
            _ = try await transcribeAudioFile(
                track.url,
                source: track.source,
                timeOffset: track.startTime,
                firstMediaTime: track.firstMediaTime,
                generation: currentGeneration
            )
        }
    }

    private func transcribeAudioFile(
        _ url: URL,
        source: AudioSource?,
        timeOffset: TimeInterval,
        firstMediaTime: TimeInterval,
        generation currentGeneration: UUID
    ) async throws -> [TranscriptSegment] {
        try requireCurrentGeneration(currentGeneration)
        guard models.installed.contains(activeModel) else { throw WhisperError.modelMissing }
        let modelURL = models.modelURL(for: activeModel)
        let currentTrackID = UUID()
        trackID = currentTrackID
        phase = .transcribing
        progress = 0
        let pieces = try await engine.transcribe(
            url: url, modelURL: modelURL, language: activeLanguage, cancellation: cancellation
        ) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.documentID == currentGeneration,
                      self.trackID == currentTrackID, self.isWorking else { return }
                self.progress = max(self.progress, min(1, value))
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
        progress = 1
        return collected
    }

    private func requireCurrentGeneration(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard documentID == expected else { throw CancellationError() }
    }
}

struct TranscriptionView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @ObservedObject var model: TranscriptionModel
    @ObservedObject var models: WhisperModelStore
    @State private var selectedText = ""
    @State private var copyFeedback: CopyFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("transcription.subtitle")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "waveform")
                Picker("whisper.models", selection: Binding(
                    get: { models.selectedModel },
                    set: { models.select($0) }
                )) {
                    ForEach(WhisperModel.allCases) { whisperModel in
                        Text(verbatim: whisperModel.rawValue).tag(whisperModel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.isWorking)
                Text(LocalizedStringKey(models.language.titleKey))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            if !models.isReady && !model.isWorking {
                Label("whisper.model_required", systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                    Text(model.phase == .preparing
                         ? "transcription.status.preparing"
                         : "transcription.status.transcribing")
                    if model.phase == .transcribing {
                        Text(model.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .help("whisper.track_progress")
                    }
                } else if model.phase == .finished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("transcription.status.finished")
                } else if model.phase == .failed {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text("transcription.status.failed")
                } else {
                    Image(systemName: "waveform")
                    Text("transcription.status.idle")
                }
                Spacer()
                if let fileName = model.fileName {
                    Text(fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(fileName)
                }
                if model.isWorking {
                    Button("transcription.cancel") { model.cancel() }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if model.usesSourceTimeline {
                Picker("transcription.filter.title", selection: $model.filter) {
                    Text("transcription.filter.all").tag(TranscriptFilter.all)
                    Text("source.system_audio").tag(TranscriptFilter.system)
                    Text("source.microphone").tag(TranscriptFilter.microphone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Group {
                if model.fileName == nil {
                    ContentUnavailableView {
                        Label("transcription.empty.title", systemImage: "doc.text")
                    } description: {
                        Text("transcription.empty.description")
                    }
                } else if model.usesSourceTimeline {
                    TranscriptTextView(
                        text: .constant(filteredTimelineText),
                        isEditable: false,
                        selectedText: $selectedText,
                        onCopy: reportCopyResult
                    )
                } else {
                    ZStack(alignment: .topLeading) {
                        TranscriptTextView(
                            text: $model.text,
                            isEditable: !model.isWorking,
                            selectedText: $selectedText,
                            onCopy: reportCopyResult
                        )
                        if model.text.isEmpty {
                            Text("transcription.placeholder")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

            HStack {
                if let copyFeedback {
                    Label(
                        copyFeedback.succeeded ? "transcription.copied" : "transcription.copy_failed",
                        systemImage: copyFeedback.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(copyFeedback.succeeded ? .green : .orange)
                } else {
                    Text("transcription.copy_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.chooseFile(outputFolderURL: recorder.outputFolderURL)
                } label: {
                    Label("transcription.import", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("transcription.import_help")
                .disabled(model.isWorking || !models.isReady)

                Button(action: copySelected) {
                    Label("transcription.copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .help("transcription.copy_help")
                .disabled(selectedText.isEmpty || model.isWorking)
            }
        }
        .onChange(of: model.documentID) { _, _ in
            selectedText = ""
            copyFeedback = nil
        }
        .onChange(of: model.filter) { _, _ in
            selectedText = ""
            copyFeedback = nil
        }
        .task(id: copyFeedback?.id) {
            guard copyFeedback != nil else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                copyFeedback = nil
            } catch {
                // A new copy action or page navigation cancels the previous timeout.
            }
        }
        .alert("transcription.error.title", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("common.ok") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var filteredTimelineText: String {
        TranscriptTimeline.grouped(model.segments)
            .filter { model.filter.includes($0.source) }
            .map { segment in
                let sourceName = segment.source == .system
                    ? String(localized: "source.system_audio")
                    : String(localized: "source.microphone")
                let seconds = max(0, Int(segment.startTime))
                let time = seconds >= 3_600
                    ? String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
                    : String(format: "%02d:%02d", seconds / 60, seconds % 60)
                return "[\(time) · \(sourceName)]\n\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            .joined(separator: "\n\n")
    }

    private func copySelected() {
        guard !selectedText.isEmpty else { return }
        reportCopyResult(TranscriptClipboard.copy(selectedText))
    }

    private func reportCopyResult(_ succeeded: Bool) {
        copyFeedback = CopyFeedback(succeeded: succeeded)
    }
}

private struct CopyFeedback {
    let id = UUID()
    let succeeded: Bool
}

private enum TranscriptClipboard {
    static func copy(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
}

enum TranscriptFilter: Hashable {
    case all
    case system
    case microphone

    func includes(_ source: AudioSource?) -> Bool {
        switch self {
        case .all: true
        case .system: source == .system
        case .microphone: source == .microphone
        }
    }
}

private struct TranscriptTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    @Binding var selectedText: String
    var onCopy: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedText: $selectedText)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = CopyFeedbackTextView()
        textView.onCopy = onCopy
        textView.frame = scrollView.contentView.bounds
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CopyFeedbackTextView else { return }
        textView.onCopy = onCopy
        textView.isEditable = isEditable
        if textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.isUpdating = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var selectedText: String
        var isUpdating = false

        init(text: Binding<String>, selectedText: Binding<String>) {
            _text = text
            _selectedText = selectedText
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            text = textView.string
            updateSelection(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            updateSelection(from: textView)
        }

        private func updateSelection(from textView: NSTextView) {
            selectedText = TranscriptSelection.selectedText(
                in: textView.string,
                range: textView.selectedRange()
            ) ?? ""
        }
    }
}

private final class CopyFeedbackTextView: NSTextView {
    var onCopy: ((Bool) -> Void)?

    override func copy(_ sender: Any?) {
        guard let value = TranscriptSelection.selectedText(in: string, range: selectedRange()),
              !value.isEmpty else { return }
        onCopy?(TranscriptClipboard.copy(value))
    }
}
