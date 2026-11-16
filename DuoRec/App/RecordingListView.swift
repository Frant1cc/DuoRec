import AppKit
import AVFoundation
import Combine
import SwiftUI

struct RecordingListView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @ObservedObject var transcription: TranscriptionModel
    @ObservedObject var models: WhisperModelStore
    let openTranscription: () -> Void
    let openLanguageRecognition: () -> Void

    @State private var preview = RecordingPreview()
    @State private var recordings: [SavedRecording]?
    @State private var loadError: String?
    @State private var refreshCount = 0
    @State private var pendingTrash: SavedRecording?
    @State private var trashing: URL?
    @State private var trashError: String?
    @State private var showsModelRequired = false
    @State private var renameDraft: RenameDraft?
    @State private var renaming = false
    @FocusState private var renameFocus: URL?

    private struct RefreshRequest: Equatable {
        let lastSaved: URL?
        let count: Int
    }

    private struct RenameDraft {
        let recording: SavedRecording
        var name: String
        var error: String?

        var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
        var canSave: Bool { !trimmedName.isEmpty && trimmedName != recording.editableName }
    }

    var body: some View {
        @Bindable var preview = preview
        return Group {
            if let loadError {
                ContentUnavailableView {
                    Label("recordings.load_failed", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("recordings.retry") { refreshCount += 1 }
                }
            } else if let recordings {
                if recordings.isEmpty {
                    ContentUnavailableView(
                        "recordings.empty.title", systemImage: "waveform",
                        description: Text("recordings.empty.description")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(recordings) { recording in
                                row(for: recording)
                                if recording.id != recordings.last?.id { Divider() }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            } else {
                ProgressView("recordings.loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let recording = preview.recording {
                RecordingPreviewBar(preview: preview, recording: recording, toggle: { togglePreview(recording) })
                    .id(recording.id)
            }
        }
        .task(id: RefreshRequest(lastSaved: recorder.lastRecordingURL, count: refreshCount)) {
            await refresh(from: recorder.outputFolderURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCount += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            if let item = notification.object as? AVPlayerItem { preview.finished(item) }
        }
        .task(id: preview.isPlaying) {
            while preview.isPlaying && !Task.isCancelled {
                preview.updatePosition()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .onDisappear { preview.stop() }
        .alert("recordings.trash.confirm", isPresented: presentation(for: $pendingTrash), presenting: pendingTrash) { recording in
            Button("recordings.trash.action", role: .destructive) {
                let folder = recorder.outputFolderURL
                Task { await moveToTrash(recording, from: folder) }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { recording in
            if let companion = recording.companion {
                Text("recordings.trash.pair \(recording.id.lastPathComponent) \(companion.url.lastPathComponent)")
            } else {
                Text("recordings.trash.single \(recording.id.lastPathComponent)")
            }
        }
        .alert("recordings.trash.failed", isPresented: presentation(for: $trashError), presenting: trashError) { _ in
            Button("common.ok") {}
        } message: { Text($0) }
        .alert("recordings.playback.failed", isPresented: presentation(for: $preview.error), presenting: preview.error) { _ in
            Button("common.ok") {}
        } message: { Text($0) }
        .alert("recordings.transcribe", isPresented: $showsModelRequired) {
            Button("navigation.language_recognition", action: openLanguageRecognition)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("whisper.model_required")
        }
    }

    private func row(for recording: SavedRecording) -> some View {
        let isPlaying = preview.isPlaying && preview.recording?.id == recording.id
        let playbackAction: LocalizedStringKey = isPlaying ? "recordings.pause" : "recordings.play"
        let draft = renameDraft.flatMap { $0.recording.id == recording.id ? $0 : nil }
        return HStack(spacing: 12) {
            Button { togglePreview(recording) } label: {
                Label(playbackAction, systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(playbackAction)

            VStack(alignment: .leading, spacing: 3) {
                if let draft {
                    renameField(for: draft)
                } else {
                    Text(recording.displayTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(recording.id.lastPathComponent)
                }
                Text(recording.details)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: draft == nil ? .combine : .contain)

            if let draft {
                Button("common.cancel", action: cancelRename)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(renaming)
                Button("common.save", action: saveRename)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canSave || renaming || isTranscribing(recording))
            } else {
                Button("recordings.transcribe") { transcribe(recording) }
                    .buttonStyle(.bordered)
                    .disabled(transcription.isWorking)

                Menu {
                    Button("recordings.rename.action", systemImage: "pencil") {
                        renameDraft = RenameDraft(recording: recording, name: recording.editableName)
                    }
                    .disabled(renameDraft != nil || trashing != nil || isTranscribing(recording))
                    Divider()
                    Button("recordings.trash.action", systemImage: "trash", role: .destructive) {
                        pendingTrash = recording
                    }
                    .disabled(trashing != nil || isTranscribing(recording))
                } label: {
                    Label("recordings.more", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("recordings.more")
            }
        }
        .padding(.vertical, 9)
        .disabled(trashing == recording.id)
    }

    private func renameField(for draft: RenameDraft) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("recordings.rename.name", text: Binding(
                get: { renameDraft?.name ?? "" },
                set: { name in
                    guard !renaming, renameDraft?.name != name else { return }
                    renameDraft?.name = name
                    renameDraft?.error = nil
                }
            ))
            .textFieldStyle(.roundedBorder)
            .focused($renameFocus, equals: draft.recording.id)
            .onSubmit(saveRename)
            .task { renameFocus = draft.recording.id }
            .disabled(renaming)
            if let error = draft.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func cancelRename() {
        guard !renaming else { return }
        renameDraft = nil
        renameFocus = nil
    }

    private func saveRename() {
        guard let draft = renameDraft, draft.canSave, !renaming, !isTranscribing(draft.recording) else { return }
        let folder = recorder.outputFolderURL
        renaming = true
        Task {
            defer { renaming = false }
            do {
                let renamed = try await RecordingLibrary.rename(draft.recording, to: draft.trimmedName, in: folder)
                if let index = recordings?.firstIndex(where: { $0.id == draft.recording.id }) {
                    recordings?[index] = renamed
                }
                preview.didRename(from: draft.recording.id, to: renamed, in: folder)
                recorder.didRenameRecording(from: draft.recording.id, to: renamed.id)
                renameDraft = nil
                renameFocus = nil
                refreshCount += 1
            } catch {
                renameDraft?.error = error.localizedDescription
                renaming = false
                renameFocus = draft.recording.id
            }
        }
    }

    private func togglePreview(_ recording: SavedRecording) {
        preview.toggle(recording, in: recorder.outputFolderURL)
    }

    private func transcribe(_ recording: SavedRecording) {
        guard !transcription.isWorking, trashing != recording.id else { return }
        guard !models.installed.isEmpty else {
            showsModelRequired = true
            return
        }
        if transcription.transcribe(url: recording.id, outputFolderURL: recorder.outputFolderURL) != nil {
            openTranscription()
        }
    }

    private func isTranscribing(_ recording: SavedRecording) -> Bool {
        guard transcription.isWorking, let source = transcription.fileURL?.standardizedFileURL else { return false }
        return recording.files.contains { $0.url.standardizedFileURL == source }
    }

    private func refresh(from folder: URL) async {
        do {
            let loaded = try await RecordingLibrary.load(from: folder)
            try Task.checkCancellation()
            guard folder == recorder.outputFolderURL else { return }
            if let active = preview.recording,
               !loaded.contains(where: { $0.id == active.id && $0.file == active.file }) {
                preview.stop()
            }
            if let draft = renameDraft, !renaming, !loaded.contains(where: { $0.id == draft.recording.id }) {
                cancelRename()
            }
            recordings = loaded
            loadError = nil
        } catch {
            guard !Task.isCancelled, folder == recorder.outputFolderURL else { return }
            preview.stop()
            loadError = error.localizedDescription
        }
    }

    private func moveToTrash(_ recording: SavedRecording, from folder: URL) async {
        guard trashing == nil, !isTranscribing(recording) else { return }
        trashing = recording.id
        let hasScope = folder.startAccessingSecurityScopedResource()
        defer {
            if hasScope { folder.stopAccessingSecurityScopedResource() }
            trashing = nil
            refreshCount += 1
        }

        let files = recording.files
        guard folder == recorder.outputFolderURL, files.allSatisfy(\.isUnchanged) else {
            trashError = String(localized: "recordings.trash.changed")
            return
        }

        if preview.recording?.id == recording.id { preview.stop() }
        var moved: [URL] = []
        do {
            // Move the M4A first so a remaining legacy source file still appears in the list.
            for file in files {
                let trashed = try await NSWorkspace.shared.recycle([file.url])
                guard trashed.count == 1 else {
                    trashError = String(localized: "recordings.trash.incomplete")
                    break
                }
                moved.append(file.url)
            }
        } catch {
            trashError = error.localizedDescription
        }
        recorder.didTrashRecordings(moved)
    }

    private func presentation<Value>(for value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

private struct RecordingPreviewBar: View {
    let preview: RecordingPreview
    let recording: SavedRecording
    let toggle: () -> Void
    @State private var scrubPosition: TimeInterval?

    var body: some View {
        let playbackAction: LocalizedStringKey = preview.isPlaying ? "recordings.pause" : "recordings.play"
        HStack(spacing: 12) {
            Button(action: toggle) {
                Label(playbackAction, systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(playbackAction)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(formatRecordingTime(scrubPosition ?? preview.position))
                    Slider(
                        value: Binding(
                            get: { scrubPosition ?? preview.position },
                            set: { seconds in
                                if scrubPosition != nil {
                                    scrubPosition = seconds
                                } else {
                                    preview.seek(to: seconds)
                                }
                            }
                        ),
                        in: 0...recording.duration,
                        label: { Text("recordings.playback.position") },
                        onEditingChanged: { editing in
                            if editing {
                                scrubPosition = preview.position
                            } else if let scrubPosition {
                                preview.seek(to: scrubPosition)
                                self.scrubPosition = nil
                            }
                        }
                    )
                    .labelsHidden()
                    Text(formatRecordingTime(recording.duration))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private extension SavedRecording {
    var displayTitle: String {
        name ?? dateLabel ?? id.deletingPathExtension().lastPathComponent
    }

    var details: String {
        [
            name == nil ? nil : dateLabel,
            formatRecordingTime(duration),
            ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var dateLabel: String? {
        guard let date else { return nil }
        let format = Date.FormatStyle().month(.abbreviated).day().hour().minute()
        return date.formatted(Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) ? format : format.year())
    }
}

private func formatRecordingTime(_ duration: TimeInterval) -> String {
    let seconds = Int(duration)
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    let remainder = seconds % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
        : String(format: "%02d:%02d", minutes, remainder)
}
