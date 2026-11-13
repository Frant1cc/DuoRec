import AppKit
import SwiftUI

struct TranscriptionView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @ObservedObject var model: TranscriptionModel
    @ObservedObject var models: WhisperModelStore
    @State private var selectedText = ""
    @State private var copyFeedback: CopyFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !models.installed.isEmpty {
                Picker("transcription.model", selection: Binding(
                    get: { models.transcriptionModel },
                    set: { selection in
                        if let selection { models.select(selection) }
                    }
                )) {
                    ForEach(models.installedModels) { whisperModel in
                        Text(verbatim: whisperModel.rawValue).tag(Optional(whisperModel))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.isWorking)
            } else if !model.isWorking {
                Label("whisper.model_required", systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if model.phase != .idle {
                HStack(spacing: 10) {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                        Text(model.phase == .preparing
                             ? "transcription.status.preparing"
                             : "transcription.status.transcribing")
                        if model.phase == .transcribing {
                            Text(model.progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .help("whisper.total_progress")
                        }
                    } else if model.phase == .finished {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("transcription.status.finished")
                    } else if model.phase == .failed {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        Text("transcription.status.failed")
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
            }

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

            if let copyFeedback {
                Label(
                    copyFeedback.succeeded ? "transcription.copied" : "transcription.copy_failed",
                    systemImage: copyFeedback.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(copyFeedback.succeeded ? .green : .orange)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.chooseFile(outputFolderURL: recorder.outputFolderURL)
                } label: {
                    Label("transcription.import", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("transcription.import_help")
                .disabled(model.isWorking || models.installed.isEmpty)

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
