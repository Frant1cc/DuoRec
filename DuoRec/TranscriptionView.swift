import AppKit
import AVFoundation
import Combine
import Speech
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TranscriptionModel: ObservableObject {
    enum Phase {
        case idle
        case preparing
        case transcribing
        case finished
    }

    @Published var text = ""
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var usesSourceTimeline = false
    @Published private(set) var fileName: String?
    @Published private(set) var phase: Phase = .idle
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var generation = UUID()

    var isWorking: Bool { phase == .preparing || phase == .transcribing }

    func chooseFile(outputFolderURL: URL) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "transcription.file_picker.title")
        panel.prompt = String(localized: "transcription.file_picker.choose")
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url: url, outputFolderURL: outputFolderURL)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        phase = .idle
        text = ""
        segments = []
        usesSourceTimeline = false
        fileName = nil
        errorMessage = nil
    }

    private func start(url: URL, outputFolderURL: URL) {
        cancel()
        let currentGeneration = UUID()
        generation = currentGeneration
        fileName = url.lastPathComponent
        phase = .preparing

        task = Task {
            let hasFileScope = url.startAccessingSecurityScopedResource()
            let isSavedRecording = url.deletingLastPathComponent().standardizedFileURL == outputFolderURL.standardizedFileURL
            let hasFolderScope = isSavedRecording && outputFolderURL.startAccessingSecurityScopedResource()
            defer {
                if hasFileScope { url.stopAccessingSecurityScopedResource() }
                if hasFolderScope { outputFolderURL.stopAccessingSecurityScopedResource() }
            }

            do {
                if let dualTrackURL = try await AudioTrackExtractor.transcriptionSourceURL(for: url) {
                    usesSourceTimeline = true
                    try await transcribeDualTrackFile(dualTrackURL, generation: currentGeneration)
                } else {
                    _ = try await transcribeAudioFile(
                        url, source: nil, timeOffset: 0, firstMediaTime: 0, generation: currentGeneration
                    )
                }
                guard generation == currentGeneration, !Task.isCancelled else { return }
                phase = .finished
                let hasSpeech = usesSourceTimeline ? !segments.isEmpty : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !hasSpeech { errorMessage = String(localized: "transcription.error.no_speech") }
            } catch {
                guard generation == currentGeneration, !Task.isCancelled else { return }
                phase = .idle
                errorMessage = error.localizedDescription
            }

            guard generation == currentGeneration else { return }
            analyzer = nil
            task = nil
        }
    }

    private func transcribeDualTrackFile(_ url: URL, generation currentGeneration: UUID) async throws {
        let temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuoRec-Transcription-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryFolder) }

        let tracks = try await AudioTrackExtractor.extractTracks(in: url, to: temporaryFolder)
        guard !tracks.isEmpty else { throw TranscriptionError.unreadableFile }
        for track in tracks {
            try Task.checkCancellation()
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
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else {
            throw TranscriptionError.unsupportedLanguage
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let modules: [any SpeechModule] = [transcriber]
        if await AssetInventory.status(forModules: modules) != .installed {
            guard let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                throw TranscriptionError.modelUnavailable
            }
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.unreadableFile
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        phase = .transcribing

        let results = Task { @MainActor in
            var collected: [TranscriptSegment] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let words = String(result.text.characters)
                guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let relativeStart = result.range.start.seconds
                let startTime = max(
                    firstMediaTime,
                    (relativeStart.isFinite ? relativeStart : 0) + timeOffset
                )
                let relativeEnd = result.range.end.seconds
                let safeRelativeEnd = relativeEnd.isFinite
                    ? relativeEnd
                    : (relativeStart.isFinite ? relativeStart : 0)
                let segment = TranscriptSegment(
                    source: source,
                    startTime: startTime,
                    endTime: max(startTime, safeRelativeEnd + timeOffset),
                    text: words
                )
                collected.append(segment)
                if generation == currentGeneration {
                    if source != nil {
                        segments.append(segment)
                        segments.sort { $0.startTime < $1.startTime }
                    } else {
                        text += words
                    }
                }
            }
            return collected
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await results.value
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

private enum TranscriptionError: LocalizedError {
    case unsupportedLanguage
    case modelUnavailable
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: String(localized: "transcription.error.unsupported_language")
        case .modelUnavailable: String(localized: "transcription.error.model_unavailable")
        case .unreadableFile: String(localized: "transcription.error.unreadable_file")
        }
    }
}

struct TranscriptionView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @StateObject private var model = TranscriptionModel()
    @State private var selectedText = ""
    @State private var filter: TranscriptFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("transcription.title")
                        .font(.title2.weight(.semibold))
                    Text("transcription.subtitle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("transcription.import") {
                    model.chooseFile(outputFolderURL: recorder.outputFolderURL)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }

            HStack(spacing: 10) {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                    Text(model.phase == .preparing
                         ? "transcription.status.preparing"
                         : "transcription.status.transcribing")
                } else if model.phase == .finished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("transcription.status.finished")
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
                Picker("transcription.filter.title", selection: $filter) {
                    Text("transcription.filter.all").tag(TranscriptFilter.all)
                    Text("source.system_audio").tag(TranscriptFilter.system)
                    Text("source.microphone").tag(TranscriptFilter.microphone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Group {
                if model.usesSourceTimeline {
                    TranscriptTextView(
                        text: .constant(filteredTimelineText),
                        isEditable: false,
                        selectedText: $selectedText
                    )
                } else {
                    ZStack(alignment: .topLeading) {
                        TranscriptTextView(
                            text: $model.text,
                            isEditable: !model.isWorking,
                            selectedText: $selectedText
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
                Text("transcription.copy_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("transcription.copy_selected") { copySelected() }
                    .disabled(selectedText.isEmpty || model.isWorking)
                Button("transcription.copy_all") { copy(allVisibleText) }
                    .disabled(allVisibleText.isEmpty || model.isWorking)
            }
        }
        .padding(22)
        .frame(minWidth: 580, minHeight: 440)
        .onDisappear { model.cancel() }
        .onChange(of: model.fileName) { _, _ in
            selectedText = ""
            filter = .all
        }
        .onChange(of: filter) { _, _ in selectedText = "" }
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
            .filter { filter.includes($0.source) }
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

    private var allVisibleText: String {
        model.usesSourceTimeline ? filteredTimelineText : model.text
    }

    private func copySelected() {
        guard !selectedText.isEmpty else { return }
        copy(selectedText)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private enum TranscriptFilter: Hashable {
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

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedText: $selectedText)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
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
        guard let textView = scrollView.documentView as? NSTextView else { return }
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
