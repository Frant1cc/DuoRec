@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreGraphics
import CoreMedia
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
    @Published private(set) var hasScreenPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published var selectedMicrophoneID: String?
    @Published var errorMessage: String?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var outputFolderURL: URL
    @Published private(set) var isMonitoring = false
    @Published var microphoneBoostDB: Float {
        didSet { UserDefaults.standard.set(microphoneBoostDB, forKey: Self.microphoneBoostKey) }
    }

    private let captureQueue = DispatchQueue(label: "com.frant1c.interview-recorder.capture", qos: .userInitiated)
    private var captureOutput: CaptureOutput?
    private var stream: SCStream?
    private var monitorStream: SCStream?
    private var monitorOutput: CaptureOutput?
    private var rawRecordingURL: URL?
    private var elapsedTask: Task<Void, Never>?
    private var isAccessingSecurityScopedOutput = false

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
    var isBusy: Bool { state != .idle || isMonitoring }
    var isTransitioning: Bool { state == .preparing || state == .finishing }
    var hasAllPermissions: Bool { hasScreenPermission && hasMicrophonePermission }

    var outputFolderDisplayName: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if outputFolderURL == downloads?.appendingPathComponent("DuoRec", isDirectory: true) {
            return String(localized: "output.default_folder_name")
        }
        return outputFolderURL.lastPathComponent
    }

    var statusText: String {
        switch state {
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

    func refreshPermissions() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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

        if !CGPreflightScreenCaptureAccess() {
            hasScreenPermission = CGRequestScreenCaptureAccess()
        }

        refreshPermissions()
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
        guard state == .idle else { return }

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
            guard hasScreenPermission else {
                throw RecorderError.permission(String(localized: "error.permission.screen_recording"))
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
                        guard let self else { return }
                        switch source {
                        case .system: self.systemLevel = level
                        case .microphone: self.microphoneLevel = level
                        }
                    }
                },
                errorHandler: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.errorMessage = message
                    }
                }
            )

            let stream = try await makeStream(output: output)

            captureOutput = output
            self.stream = stream
            try await stream.startCapture()

            state = .recording
            startElapsedTimer()
        } catch {
            await cleanUpAfterFailure()
            errorMessage = userFacingMessage(for: error)
            state = .idle
        }
    }

    func toggleInputMonitoring() async {
        if isMonitoring {
            await stopInputMonitoring()
        } else {
            await startInputMonitoring()
        }
    }

    private func startInputMonitoring() async {
        guard state == .idle, !isMonitoring else { return }
        errorMessage = nil

        do {
            await requestPermissions()
            guard hasMicrophonePermission else {
                throw RecorderError.permission(String(localized: "error.permission.microphone"))
            }
            guard hasScreenPermission else {
                throw RecorderError.permission(String(localized: "error.permission.screen_monitoring"))
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
            isMonitoring = true
        } catch {
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
        guard state == .recording, let stream, let captureOutput else { return }
        state = .finishing
        elapsedTask?.cancel()
        elapsedTask = nil

        do {
            try await stream.stopCapture()
            let rawURL = try await captureOutput.finish()
            let finalURL = try finalURL(for: rawURL)
            try await AudioMixer.mixTracks(in: rawURL, to: finalURL)
            try? FileManager.default.removeItem(at: rawURL)

            lastRecordingURL = finalURL
            NSSound(named: "Glass")?.play()
        } catch {
            if let rawRecordingURL, FileManager.default.fileExists(atPath: rawRecordingURL.path) {
                lastRecordingURL = try? preserveRawRecording(rawRecordingURL)
            }
            errorMessage = userFacingMessage(for: error)
        }

        self.stream = nil
        self.captureOutput = nil
        rawRecordingURL = nil
        endAccessingOutputFolder()
        systemLevel = 0
        microphoneLevel = 0
        state = .idle
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
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputFolderURL, withIntermediateDirectories: true)

        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("DuoRec", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)

        return support.appendingPathComponent("active-\(UUID().uuidString).m4a")
    }

    private func finalURL(for rawURL: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let baseName = "\(formatter.string(from: Date())) DuoRec"
        return uniqueURL(in: outputFolderURL, baseName: baseName, extension: "m4a")
    }

    private func preserveRawRecording(_ rawURL: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let destination = uniqueURL(
            in: outputFolderURL,
            baseName: "\(formatter.string(from: Date())) DuoRec - \(String(localized: "recording.raw_tracks_filename"))",
            extension: "m4a"
        )
        try FileManager.default.moveItem(at: rawURL, to: destination)
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
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        captureOutput = nil
        if let rawRecordingURL {
            try? FileManager.default.removeItem(at: rawRecordingURL)
        }
        rawRecordingURL = nil
        endAccessingOutputFolder()
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func userFacingMessage(for error: Error) -> String {
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
