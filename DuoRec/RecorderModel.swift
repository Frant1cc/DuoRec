@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreGraphics
import CoreMedia
import OSLog
@preconcurrency import ScreenCaptureKit

@MainActor
final class RecorderModel: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var systemLevel = 0.0
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var screenAccess: ScreenRecordingAccess = .checking
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published var selectedMicrophoneID: String?
    @Published var errorMessage: String?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var outputFolderURL: URL
    @Published private(set) var isMonitoring = false
    @Published var isUpdateSessionActive = false
    @Published var microphoneBoostDB: Float {
        didSet { UserDefaults.standard.set(microphoneBoostDB, forKey: Self.microphoneBoostKey) }
    }

    private let captureQueue = DispatchQueue(label: "com.frant1c.interview-recorder.capture", qos: .userInitiated)
    private var captureOutput: CaptureOutput?
    private var stream: SCStream?
    private var monitorStream: SCStream?
    private var monitorOutput: CaptureOutput?
    private var rawRecordingURL: URL?
    private var preparationTask: Task<Void, Never>?
    private var finishTask: Task<Bool, Never>?
    private var sessionID: UUID?
    private var pendingCaptureError: String?
    private var didCheckRecovery = false
    private var lastSaveSucceeded = true
    @Published private(set) var isTerminating = false
    @Published private(set) var hasRecoveryFiles = false
    private var elapsedTask: Task<Void, Never>?
    private var isAccessingSecurityScopedOutput = false
    private var permissionCheckTask: Task<ScreenRecordingAccess, Never>?
    private var permissionRevision = 0
    private let permissionLogger = Logger(subsystem: "frant1c.duorec", category: "RecordingPermission")

    private static let outputFolderBookmarkKey = "outputFolderBookmark"
    private static let microphoneBoostKey = "microphoneBoostDB"

    init() {
        outputFolderURL = Self.defaultOutputFolderURL()
        microphoneBoostDB = UserDefaults.standard.object(forKey: Self.microphoneBoostKey) == nil
            ? 6
            : UserDefaults.standard.float(forKey: Self.microphoneBoostKey)
        restoreOutputFolderBookmark()
    }

    var isRecording: Bool { state == .recording }
    var isPreparing: Bool { state == .preparing }
    var isFinishing: Bool { state == .finishing }
    var isBusy: Bool { state != .idle || isMonitoring || isTerminating }
    var isTransitioning: Bool { state == .preparing || state == .finishing || isTerminating || isUpdateSessionActive }
    var hasAllPermissions: Bool { hasScreenPermission && hasMicrophonePermission }
    var hasScreenPermission: Bool { screenAccess == .granted }

    var outputFolderDisplayName: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if outputFolderURL == downloads?.appendingPathComponent("DuoRec", isDirectory: true) {
            return String(localized: "output.default_folder_name")
        }
        return outputFolderURL.lastPathComponent
    }

    var statusText: String {
        if isUpdateSessionActive { return String(localized: "updates.in_progress") }
        return switch state {
        case .idle:
            isMonitoring
                ? String(localized: "status.monitoring")
                : String(localized: "status.ready")
        case .preparing: String(localized: "status.preparing")
        case .recording: String(localized: "status.recording")
        case .finishing: String(localized: "status.finishing")
        }
    }

    var primaryActionTitle: String {
        switch state {
        case .idle: String(localized: "action.start_recording")
        case .preparing: String(localized: "action.preparing")
        case .recording: String(localized: "action.stop_and_save")
        case .finishing: String(localized: "action.saving")
        }
    }

    var formattedElapsedTime: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    func refreshPermissions() async {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if isRecording || isMonitoring { return }
        if let permissionCheckTask {
            _ = await permissionCheckTask.value
            return
        }

        screenAccess = .checking
        let revision = permissionRevision
        let task = Task {
            await ScreenRecordingAccess.check {
                // Use the same framework as capture: the CoreGraphics preflight can
                // disagree with ScreenCaptureKit and must not decide this badge.
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
        }
        permissionCheckTask = task
        let result = await task.value
        permissionCheckTask = nil
        guard revision == permissionRevision else { return }
        screenAccess = result
        permissionLogger.notice("Permission check: \(String(describing: result), privacy: .public)")
    }

    private func captureAccessSucceeded() {
        permissionRevision += 1
        screenAccess = .granted
    }

    private func captureAccessFailed(_ error: Error) {
        guard ScreenRecordingAccess.isPermissionDenial(error) else { return }
        permissionRevision += 1
        screenAccess = .denied
        permissionLogger.error("ScreenCaptureKit denied capture access")
    }

    func refreshMicrophones() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        microphones = session.devices

        if selectedMicrophoneID == nil || !microphones.contains(where: { $0.uniqueID == selectedMicrophoneID }) {
            selectedMicrophoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID
        }
    }

    func requestPermissions() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            hasMicrophonePermission = await AVCaptureDevice.requestAccess(for: .audio)
        }

        await refreshPermissions()
        refreshMicrophones()
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "folder_picker.title")
        panel.prompt = String(localized: "folder_picker.choose")
        panel.message = String(localized: "folder_picker.message")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolderURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolderURL = url

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.outputFolderBookmarkKey)
        } catch {
            errorMessage = String(localized: "error.folder_bookmark")
        }
    }

    func startRecording() async {
        guard state == .idle, !isTerminating, !isUpdateSessionActive else { return }
        state = .preparing
        let task = Task { await prepareRecording() }
        preparationTask = task
        await task.value
        preparationTask = nil
    }

    private func prepareRecording() async {
        let id = UUID()
        sessionID = id
        lastSaveSucceeded = true
        pendingCaptureError = nil
        if isMonitoring {
            await stopInputMonitoring()
        }

        state = .preparing
        errorMessage = nil
        systemLevel = 0
        microphoneLevel = 0

        do {
            await requestPermissions()
            guard hasMicrophonePermission else {
                throw RecorderError.permission(String(localized: "error.permission.microphone"))
            }
            try beginAccessingOutputFolder()
            let rawURL = try makeRawRecordingURL()
            rawRecordingURL = rawURL

            let writer = try DualTrackAudioWriter(outputURL: rawURL)
            let output = CaptureOutput(
                writer: writer,
                microphoneGainDB: microphoneBoostDB,
                levelHandler: { [weak self] source, level in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == id,
                              self.state == .preparing || self.state == .recording else { return }
                        switch source {
                        case .system: self.systemLevel = level
                        case .microphone: self.microphoneLevel = level
                        }
                    }
                },
                errorHandler: { [weak self] message in
                    Task { @MainActor [weak self] in
                        await self?.handleCaptureFailure(message, session: id)
                    }
                }
            )

            captureOutput = output
            let stream = try await makeStream(output: output)
            self.stream = stream
            try await stream.startCapture()
            captureAccessSucceeded()

            state = .recording
            startElapsedTimer()
            if let pendingCaptureError {
                await handleCaptureFailure(pendingCaptureError, session: id)
            }
        } catch {
            captureAccessFailed(error)
            await cleanUpAfterFailure()
            errorMessage = userFacingMessage(for: error)
            state = .idle
        }
    }

    func toggleInputMonitoring() async {
        guard state == .idle, !isTerminating, !isUpdateSessionActive else { return }
        state = .preparing
        let task = Task {
            if isMonitoring {
                await stopInputMonitoring()
            } else {
                await startInputMonitoring()
            }
            state = .idle
        }
        preparationTask = task
        await task.value
        preparationTask = nil
    }

    private func startInputMonitoring() async {
        guard !isMonitoring else { return }
        errorMessage = nil

        do {
            await requestPermissions()
            guard hasMicrophonePermission else {
                throw RecorderError.permission(String(localized: "error.permission.microphone"))
            }
            let output = CaptureOutput(
                writer: nil,
                microphoneGainDB: microphoneBoostDB,
                levelHandler: makeLevelHandler(),
                errorHandler: makeCaptureErrorHandler()
            )
            let stream = try await makeStream(output: output)
            monitorOutput = output
            monitorStream = stream
            try await stream.startCapture()
            captureAccessSucceeded()
            isMonitoring = true
        } catch {
            captureAccessFailed(error)
            monitorStream = nil
            monitorOutput = nil
            isMonitoring = false
            errorMessage = userFacingMessage(for: error)
        }
    }

    private func stopInputMonitoring() async {
        if let monitorStream {
            try? await monitorStream.stopCapture()
        }
        monitorStream = nil
        monitorOutput = nil
        isMonitoring = false
        systemLevel = 0
        microphoneLevel = 0
    }

    func stopRecording() async {
        _ = await finishRecording()
    }

    private func handleCaptureFailure(_ message: String, session id: UUID) async {
        guard sessionID == id else { return }
        if state == .preparing {
            pendingCaptureError = message
            return
        }
        guard state == .recording else { return }
        errorMessage = message
        _ = await finishRecording()
    }

    private func finishRecording() async -> Bool {
        if let finishTask { return await finishTask.value }
        guard state == .recording, let stream, let captureOutput else { return lastSaveSucceeded }
        state = .finishing
        elapsedTask?.cancel()
        elapsedTask = nil
        let task = Task { await saveRecording(stream: stream, output: captureOutput) }
        finishTask = task
        let saved = await task.value
        finishTask = nil
        lastSaveSucceeded = saved
        state = .idle
        return saved
    }

    private func saveRecording(stream: SCStream, output: CaptureOutput) async -> Bool {
        defer {
            self.stream = nil
            captureOutput = nil
            rawRecordingURL = nil
            sessionID = nil
            pendingCaptureError = nil
            endAccessingOutputFolder()
            systemLevel = 0
            microphoneLevel = 0
        }
        do {
            let rawURL = try await RecordingFinalizer.finish(
                stopping: { try await stream.stopCapture() },
                finishing: { try await output.finish() }
            )
            try await saveRecordingFile(rawURL)
            NSSound(named: "Glass")?.play()
            return true
        } catch {
            // A failed writer may still contain readable movie fragments. Only
            // advertise a backup after AVFoundation has verified its audio.
            if let rawRecordingURL, await preserveReadableRecording(rawRecordingURL) {
                errorMessage = String(localized: "error.saved_raw_recording")
                return true
            }
            hasRecoveryFiles = true
            errorMessage = String(localized: "error.recording_retained") + "\n" + error.localizedDescription
            return false
        }
    }

    private func saveRecordingFile(_ rawURL: URL) async throws {
        let destination = finalURL()
        try await AudioRecordingFile.save(rawURL, to: destination)
        lastRecordingURL = destination
    }

    private func preserveReadableRecording(_ rawURL: URL) async -> Bool {
        do {
            lastRecordingURL = try await preserveRawRecording(rawURL)
            return true
        } catch {
            return false
        }
    }

    func prepareForTermination() async -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        if let preparationTask { await preparationTask.value }
        let saved = await finishRecording()
        await stopInputMonitoring()
        // Keep new recordings disabled until AppKit has actually exited.
        if !saved { isTerminating = false }
        return saved
    }

    func recoverInterruptedRecordings() async {
        guard !didCheckRecovery, state == .idle, !isTerminating else { return }
        didCheckRecovery = true
        state = .finishing
        let task = Task { await recoverFiles() }
        finishTask = task
        _ = await task.value
        finishTask = nil
        state = .idle
    }

    private func recoverFiles() async -> Bool {
        defer { endAccessingOutputFolder() }
        do {
            let folder = try recoveryFolder()
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("active-") && ["mov", "m4a"].contains($0.pathExtension) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { return true }
            try beginAccessingOutputFolder()
            var failed = false
            for file in files {
                do { try await saveRecordingFile(file) }
                catch { failed = true }
            }
            hasRecoveryFiles = failed
            if failed { errorMessage = String(localized: "error.recovery_retained") }
            return !failed
        } catch {
            hasRecoveryFiles = true
            errorMessage = String(localized: "error.recovery_retained") + "\n" + error.localizedDescription
            return false
        }
    }

    func revealRecoveryFiles() {
        if let folder = try? recoveryFolder() { NSWorkspace.shared.open(folder) }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startElapsedTimer() {
        elapsedSeconds = 0
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.elapsedSeconds += 1
            }
        }
    }

    private func preferredDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let mainID = CGMainDisplayID()
        return displays.first(where: { $0.displayID == mainID }) ?? displays.first
    }

    private func makeStream(output: CaptureOutput) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = preferredDisplay(from: content.displays) else {
            throw RecorderError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = selectedMicrophoneID

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: captureQueue)
        try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: captureQueue)
        return stream
    }

    private func makeLevelHandler() -> @Sendable (AudioSource, Double) -> Void {
        { [weak self] source, level in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch source {
                case .system: self.systemLevel = level
                case .microphone: self.microphoneLevel = level
                }
            }
        }
    }

    private func makeCaptureErrorHandler() -> @Sendable (String) -> Void {
        { [weak self] message in
            Task { @MainActor [weak self] in
                self?.errorMessage = message
            }
        }
    }

    private func makeRawRecordingURL() throws -> URL {
        try recoveryFolder().appendingPathComponent("active-\(UUID().uuidString).mov")
    }

    private func recoveryFolder() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("DuoRec", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    private func finalURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let baseName = "\(formatter.string(from: Date())) DuoRec"
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let candidate = outputFolderURL.appendingPathComponent(name).appendingPathExtension("mp4")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func preserveRawRecording(_ rawURL: URL) async throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let destination = uniqueURL(
            in: outputFolderURL,
            baseName: "\(formatter.string(from: Date())) DuoRec - \(String(localized: "recording.raw_tracks_filename"))",
            extension: rawURL.pathExtension
        )
        try await AudioRecordingFile.preserve(rawURL, to: destination)
        return destination
    }

    private static func defaultOutputFolderURL() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return downloads.appendingPathComponent("DuoRec", isDirectory: true)
    }

    private func restoreOutputFolderBookmark() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.outputFolderBookmarkKey) else { return }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            outputFolderURL = url

            if isStale {
                let refreshedBookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshedBookmark, forKey: Self.outputFolderBookmarkKey)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.outputFolderBookmarkKey)
            outputFolderURL = Self.defaultOutputFolderURL()
        }
    }

    private func beginAccessingOutputFolder() throws {
        let defaultFolder = Self.defaultOutputFolderURL()
        if outputFolderURL != defaultFolder {
            isAccessingSecurityScopedOutput = outputFolderURL.startAccessingSecurityScopedResource()
            guard isAccessingSecurityScopedOutput else {
                throw RecorderError.outputFolderAccess
            }
        }
        try FileManager.default.createDirectory(
            at: outputFolderURL,
            withIntermediateDirectories: true
        )
    }

    private func endAccessingOutputFolder() {
        guard isAccessingSecurityScopedOutput else { return }
        outputFolderURL.stopAccessingSecurityScopedResource()
        isAccessingSecurityScopedOutput = false
    }

    private func uniqueURL(in folder: URL, baseName: String, extension fileExtension: String) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    private func cleanUpAfterFailure() async {
        if let stream { try? await stream.stopCapture() }
        if let captureOutput {
            do {
                let rawURL = try await captureOutput.finish()
                do { try await saveRecordingFile(rawURL) }
                catch {
                    lastSaveSucceeded = await preserveReadableRecording(rawURL)
                    hasRecoveryFiles = hasRecoveryFiles || !lastSaveSucceeded
                }
            } catch AudioWriterError.noAudio {
                if let rawRecordingURL { try? FileManager.default.removeItem(at: rawRecordingURL) }
            } catch {
                hasRecoveryFiles = true
                lastSaveSucceeded = false
            }
        }
        stream = nil
        captureOutput = nil
        rawRecordingURL = nil
        sessionID = nil
        pendingCaptureError = nil
        endAccessingOutputFolder()
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func userFacingMessage(for error: Error) -> String {
        if ScreenRecordingAccess.isPermissionDenial(error) {
            return String(localized: "error.permission.screen_denied")
        }
        if let recorderError = error as? RecorderError {
            return recorderError.localizedDescription
        }
        return String(
            format: String(localized: "error.retry_after_permission_change"),
            error.localizedDescription
        )
    }
}

private enum RecorderError: LocalizedError {
    case permission(String)
    case noDisplay
    case outputFolder
    case outputFolderAccess

    var errorDescription: String? {
        switch self {
        case .permission(let message): message
        case .noDisplay: String(localized: "error.no_display")
        case .outputFolder: String(localized: "error.output_folder")
        case .outputFolderAccess: String(localized: "error.output_folder_access")
        }
    }
}
