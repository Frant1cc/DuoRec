import Combine
import CryptoKit
import Foundation

nonisolated enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-turbo"
    case small
    case medium

    var id: String { rawValue }
    var fileName: String { "ggml-\(rawValue).bin" }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
    var byteCount: Int64 {
        switch self {
        case .largeV3: 3_095_033_483
        case .largeV3Turbo: 1_624_555_275
        case .small: 487_601_967
        case .medium: 1_533_763_059
        }
    }
    var sha256: String {
        switch self {
        case .largeV3: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        case .largeV3Turbo: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        case .small: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        case .medium: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
        }
    }
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
    var summaryKey: String { "whisper.model.\(rawValue).summary" }
}

nonisolated enum WhisperLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case chinese = "zh"
    case english = "en"

    var id: String { rawValue }
    var titleKey: String { "whisper.language.\(rawValue)" }
}

nonisolated enum WhisperError: LocalizedError {
    case modelMissing, invalidModel, downloadFailed, unreadableAudio, modelLoadFailed, recognitionFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing: String(localized: "whisper.error.model_missing")
        case .invalidModel: String(localized: "whisper.error.invalid_model")
        case .downloadFailed: String(localized: "whisper.error.download_failed")
        case .unreadableAudio: String(localized: "transcription.error.unreadable_file")
        case .modelLoadFailed: String(localized: "whisper.error.load_failed")
        case .recognitionFailed: String(localized: "whisper.error.recognition_failed")
        }
    }
}

nonisolated enum WhisperModelValidationError: LocalizedError {
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .sizeMismatch(let expected, let actual):
            String(format: String(localized: "whisper.error.size_mismatch"),
                   ByteCountFormatter.string(fromByteCount: actual, countStyle: .file),
                   ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))
        case .checksumMismatch: String(localized: "whisper.error.checksum_mismatch")
        }
    }
}

@MainActor
final class WhisperModelStore: ObservableObject {
    enum Transfer: Equatable {
        case connecting(WhisperModel)
        case downloading(WhisperModel, Int64)
        case pausing(WhisperModel)
        case verifying(WhisperModel)

        var model: WhisperModel {
            switch self {
            case .connecting(let model), .downloading(let model, _), .pausing(let model), .verifying(let model): model
            }
        }
    }

    @Published private(set) var selectedModel: WhisperModel
    @Published var language: WhisperLanguage {
        didSet { defaults.set(language.rawValue, forKey: "whisper.language") }
    }
    @Published private(set) var installed: Set<WhisperModel> = []
    @Published private(set) var transfer: Transfer?
    @Published private(set) var pausedDownloads: [WhisperModel: Int64] = [:]
    @Published var errorMessage: String?

    let directory: URL
    private let defaults: UserDefaults
    private var transferTask: Task<Void, Never>?
    private var transferID = UUID()

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DuoRec/WhisperModels", isDirectory: true)
        selectedModel = defaults.string(forKey: "whisper.model").flatMap(WhisperModel.init(rawValue:)) ?? .largeV3Turbo
        language = defaults.string(forKey: "whisper.language").flatMap(WhisperLanguage.init(rawValue:)) ?? .automatic
        refreshInstalled()
        refreshPausedDownloads()
    }

    var isTransferring: Bool { transfer != nil }
    var isReady: Bool { installed.contains(selectedModel) }

    func select(_ model: WhisperModel) {
        selectedModel = model
        defaults.set(model.rawValue, forKey: "whisper.model")
    }

    func modelURL(for model: WhisperModel) -> URL { directory.appendingPathComponent(model.fileName) }
    func partialURL(for model: WhisperModel) -> URL { modelURL(for: model).appendingPathExtension("partial") }

    func refreshPausedDownloads() {
        pausedDownloads = Dictionary(uniqueKeysWithValues: WhisperModel.allCases.compactMap { model in
            let bytes = WhisperDownloader.savedBytes(at: partialURL(for: model))
            return bytes > 0 ? (model, bytes) : nil
        })
    }

    func refreshInstalled() {
        installed = Set(WhisperModel.allCases.filter { model in
            let url = modelURL(for: model)
            let size = WhisperDownloader.savedBytes(at: url)
            let marker = try? String(contentsOf: url.appendingPathExtension("verified"), encoding: .utf8)
            return size == model.byteCount && marker == model.sha256
        })
    }

    @discardableResult
    func download(_ model: WhisperModel) -> Task<Void, Never>? {
        startTransfer(model, importing: nil)
    }

    @discardableResult
    func importModel(_ model: WhisperModel, from url: URL) -> Task<Void, Never>? {
        startTransfer(model, importing: url)
    }

    func cancelTransfer() {
        guard let transfer else { return }
        self.transfer = .pausing(transfer.model)
        transferTask?.cancel()
    }

    func discardPartial(_ model: WhisperModel) {
        guard transfer?.model != model else { return }
        do {
            let partial = partialURL(for: model)
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
            refreshPausedDownloads()
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ model: WhisperModel) {
        guard transfer?.model != model else { return }
        do {
            let url = modelURL(for: model)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: url.appendingPathExtension("verified"))
            refreshInstalled()
        } catch { errorMessage = error.localizedDescription }
    }

    private func startTransfer(_ model: WhisperModel, importing source: URL?) -> Task<Void, Never>? {
        guard transfer == nil, !installed.contains(model) else { return nil }
        let id = UUID()
        transferID = id
        errorMessage = nil
        transfer = source == nil ? .connecting(model) : .verifying(model)
        let task = Task {
            let staging = source == nil ? partialURL(for: model) : directory.appendingPathComponent("\(id.uuidString).importing")
            defer {
                if source != nil { try? FileManager.default.removeItem(at: staging) }
                if transferID == id {
                    refreshPausedDownloads()
                    transfer = nil
                    transferTask = nil
                }
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let source {
                    let hasScope = source.startAccessingSecurityScopedResource()
                    defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
                    // Verification/copying gigabyte-sized files must not block the interface.
                    try await WhisperModelFiles.copy(source, to: staging)
                } else {
                    let saved = WhisperDownloader.savedBytes(at: staging)
                    if saved > model.byteCount {
                        throw WhisperModelValidationError.sizeMismatch(expected: model.byteCount, actual: saved)
                    }
                    let downloader = WhisperDownloader(destination: staging, expectedSize: model.byteCount) { [weak self] bytes in
                        Task { @MainActor [weak self] in
                            guard let self, self.transferID == id else { return }
                            switch self.transfer {
                            case .connecting, .downloading:
                                self.transfer = .downloading(model, bytes)
                            default: break
                            }
                        }
                    }
                    let request = URLRequest(url: model.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                             timeoutInterval: 30)
                    let response = try await downloader.download(request)
                    try Task.checkCancellation()
                    guard response.statusCode == 200 || response.statusCode == 206 else {
                        throw WhisperError.downloadFailed
                    }
                }
                try Task.checkCancellation()
                guard transferID == id else { throw CancellationError() }
                transfer = .verifying(model)
                try await WhisperModelFiles.verify(staging, model: model)
                try Task.checkCancellation()
                guard transferID == id else { throw CancellationError() }
                let destination = modelURL(for: model)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: staging, to: destination)
                try model.sha256.write(to: destination.appendingPathExtension("verified"), atomically: true, encoding: .utf8)
                if source != nil { try? FileManager.default.removeItem(at: partialURL(for: model)) }
                refreshInstalled()
            } catch {
                guard transferID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        transferTask = task
        return task
    }
}

enum WhisperModelFiles {
    nonisolated static func verify(_ url: URL, model: WhisperModel) async throws {
        try await verify(url, expectedSize: model.byteCount, sha256: model.sha256)
    }

    nonisolated static func verify(_ url: URL, expectedSize: Int64, sha256: String) async throws {
        let work = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = Int64(try handle.seekToEnd())
            guard size == expectedSize else {
                throw WhisperModelValidationError.sizeMismatch(expected: expectedSize, actual: size)
            }
            try handle.seek(toOffset: 0)
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == sha256 else { throw WhisperModelValidationError.checksumMismatch }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    nonisolated static func copy(_ source: URL, to destination: URL) async throws {
        let work = Task.detached(priority: .utility) {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
