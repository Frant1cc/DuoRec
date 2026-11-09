import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LanguageRecognitionView: View {
    @ObservedObject var models: WhisperModelStore
    @ObservedObject var transcription: TranscriptionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("whisper.title").font(.title2.weight(.semibold))
                    Text("whisper.subtitle").font(.callout).foregroundStyle(.secondary)
                }

                GroupBox("whisper.models") {
                    VStack(spacing: 0) {
                        ForEach(Array(WhisperModel.allCases.enumerated()), id: \.element.id) { index, model in
                            if index > 0 { Divider() }
                            modelRow(model).padding(.vertical, 14)
                        }
                    }
                    .padding(.horizontal, 12)
                }

                GroupBox("whisper.language.title") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("whisper.language.title", selection: $models.language) {
                            ForEach(WhisperLanguage.allCases) { language in
                                Text(LocalizedStringKey(language.titleKey)).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(transcription.isWorking)
                        Text("whisper.language.help").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                }

                HStack {
                    Label("whisper.local_only", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("whisper.import_model", action: importModel)
                        .disabled(models.isTransferring || models.isReady || transcription.isWorking)
                }
                Text("whisper.storage_help").font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("whisper.error.title", isPresented: Binding(
            get: { models.errorMessage != nil },
            set: { if !$0 { models.errorMessage = nil } }
        )) {
            Button("common.ok") { models.errorMessage = nil }
        } message: { Text(models.errorMessage ?? "") }
    }

    private func modelRow(_ model: WhisperModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { models.select(model) } label: {
                    Image(systemName: models.selectedModel == model ? "largecircle.fill.circle" : "circle")
                        .font(.title3)
                        .foregroundStyle(models.selectedModel == model ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: model.rawValue))
                .accessibilityValue(Text(models.selectedModel == model ? "whisper.selected" : "whisper.not_selected"))
                .disabled(transcription.isWorking)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: model.rawValue).font(.headline)
                        HStack(spacing: 4) {
                            Text("whisper.disk_size")
                            Text(model.sizeDescription).monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(LocalizedStringKey(model.summaryKey)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if models.installed.contains(model) {
                    Label("whisper.installed", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Button(role: .destructive) { models.remove(model) } label: {
                        Image(systemName: "trash")
                    }
                    .help("whisper.remove")
                    .disabled(transcription.isWorking)
                } else if models.transfer?.model == model {
                    Button(models.transfer == .pausing(model) ? "whisper.pausing" : "whisper.pause") { models.cancelTransfer() }
                        .disabled(models.transfer == .pausing(model))
                } else {
                    Button(downloadTitle(for: model)) { models.download(model) }
                        .disabled(models.isTransferring || transcription.isWorking)
                    if models.pausedDownloads[model] != nil {
                        Button(role: .destructive) { models.discardPartial(model) } label: {
                            Image(systemName: "trash")
                        }
                        .help("whisper.discard_partial")
                        .disabled(transcription.isWorking)
                    }
                }
            }
            if let transfer = models.transfer, transfer.model == model {
                switch transfer {
                case .connecting:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(models.pausedDownloads[model] == nil ? "whisper.connecting" : "whisper.resuming")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .pausing:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("whisper.pausing").font(.caption).foregroundStyle(.secondary)
                    }
                case .downloading(_, let bytes):
                    let progress = min(1, Double(bytes) / Double(model.byteCount))
                    ProgressView(value: progress) {
                        HStack {
                            Text("whisper.downloading")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            Text(verbatim: "/")
                            Text(model.sizeDescription)
                            Text(progress, format: .percent.precision(.fractionLength(1)))
                                .monospacedDigit()
                        }.font(.caption)
                    }
                case .verifying:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("whisper.verifying").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let bytes = models.pausedDownloads[model] {
                HStack {
                    Text("whisper.paused")
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    Text(verbatim: "/")
                    Text(model.sizeDescription)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func downloadTitle(for model: WhisperModel) -> LocalizedStringKey {
        guard let bytes = models.pausedDownloads[model] else { return "whisper.download" }
        return bytes >= model.byteCount ? "whisper.reverify" : "whisper.resume"
    }

    private func importModel() {
        guard !models.isTransferring, !models.isReady, !transcription.isWorking else { return }
        let model = models.selectedModel
        let panel = NSOpenPanel()
        panel.title = String(localized: "whisper.import_model")
        panel.message = model.fileName
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              !models.isTransferring, !transcription.isWorking else { return }
        models.importModel(model, from: url)
    }
}
