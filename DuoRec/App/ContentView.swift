import AVFoundation
import AppKit
import Combine
import SwiftUI

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case recording
    case transcription
    case languageRecognition

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .recording: "navigation.recording"
        case .transcription: "navigation.transcription"
        case .languageRecognition: "navigation.language_recognition"
        }
    }

    var icon: String {
        switch self {
        case .recording: "waveform"
        case .transcription: "doc.text"
        case .languageRecognition: "character.bubble"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @StateObject private var whisper: WhisperModelStore
    @StateObject private var transcription: TranscriptionModel
    @State private var selection: WorkspaceSection? = .recording
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init() {
        let models = WhisperModelStore()
        _whisper = StateObject(wrappedValue: models)
        _transcription = StateObject(wrappedValue: TranscriptionModel(models: models))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(WorkspaceSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("DuoRec")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    SettingsLink {
                        Label("app.settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
            }
        } detail: {
            Group {
                switch selection ?? .recording {
                case .recording:
                    RecordingView()
                case .transcription:
                    TranscriptionView(model: transcription, models: whisper)
                case .languageRecognition:
                    LanguageRecognitionView(models: whisper, transcription: transcription)
                }
            }
            .navigationTitle((selection ?? .recording).title)
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if recorder.state != .idle && !recorder.isMonitoring {
                RecordingStatusBar()
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await recorder.recoverInterruptedRecordings()
            recorder.refreshMicrophones()
            await recorder.refreshPermissions()
        }
        .onDisappear {
            transcription.cancel()
            whisper.cancelTransfer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recorder.refreshMicrophones()
            Task { await recorder.refreshPermissions() }
        }
        .alert("alert.recording_failed.title", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )) {
            Button("common.ok") { recorder.errorMessage = nil }
            if recorder.hasRecoveryFiles {
                Button("recording.reveal_recovery") { recorder.revealRecoveryFiles() }
            }
        } message: {
            Text(recorder.errorMessage ?? String(localized: "error.unknown"))
        }
    }
}

private struct RecordingView: View {
    @EnvironmentObject private var recorder: RecorderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(recorder.statusText)
                    .font(.title2.weight(.semibold))

                if !recorder.hasAllPermissions {
                    GroupBox("permissions.title") {
                        RecordingPermissionsView()
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                meterSection
                settingsSection

                VStack(spacing: 12) {
                    if recorder.state == .idle || recorder.isMonitoring {
                        RecordingActionButton()
                            .controlSize(.large)
                    }

                    if let lastRecordingURL = recorder.lastRecordingURL {
                        Button {
                            recorder.reveal(lastRecordingURL)
                        } label: {
                            Label("recording.reveal_recent", systemImage: "folder")
                        }
                        .buttonStyle(.link)
                        .help(lastRecordingURL.path)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 660)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var meterSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                InputWaveforms()
                if let meterHelpText {
                    Text(meterHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        } label: {
            HStack {
                Text("levels.title")
                Spacer()
                Button(recorder.isMonitoring ? "monitor.stop" : "monitor.start") {
                    Task { await recorder.toggleInputMonitoring() }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(!recorder.canToggleMonitoring)
            }
        }
    }

    private var meterHelpText: LocalizedStringKey? {
        if recorder.isRecording { return "levels.help.recording" }
        if recorder.isMonitoring { return "levels.help.monitoring" }
        return nil
    }

    private var settingsSection: some View {
        GroupBox("settings.title") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                GridRow {
                    Label("settings.microphone", systemImage: "mic")
                        .foregroundStyle(.secondary)
                    Picker("settings.microphone", selection: $recorder.selectedMicrophoneID) {
                        if recorder.microphones.isEmpty {
                            Text("settings.system_default").tag(String?.none)
                        } else {
                            ForEach(recorder.microphones, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(Optional(device.uniqueID))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GridRow {
                    Label("settings.microphone_boost", systemImage: "waveform.badge.plus")
                        .foregroundStyle(.secondary)
                    Picker("settings.microphone_boost", selection: $recorder.microphoneBoostDB) {
                        Text("common.off").tag(Float(0))
                        Text("+6 dB").tag(Float(6))
                        Text("+12 dB").tag(Float(12))
                    }
                    .labelsHidden()
                }

                GridRow {
                    Label("settings.save_location", systemImage: "folder")
                        .foregroundStyle(.secondary)
                    Button {
                        recorder.chooseOutputFolder()
                    } label: {
                        HStack(spacing: 6) {
                            Text(recorder.outputFolderDisplayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .help(recorder.outputFolderURL.path)
                }
            }
            .font(.callout)
            .labelStyle(AlignedIconLabelStyle())
            .padding(10)
            .disabled(!recorder.canEditSettings)
        }
    }
}

private struct RecordingActionButton: View {
    @EnvironmentObject private var recorder: RecorderModel

    var body: some View {
        Button {
            Task {
                if recorder.isRecording {
                    await recorder.stopRecording()
                } else {
                    await recorder.startRecording()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if recorder.isPreparing || recorder.isFinishing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                }
                Text(recorder.primaryActionTitle)
            }
            .padding(.horizontal, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(recorder.isRecording ? .red : .accentColor)
        .disabled(recorder.isTransitioning)
    }
}

private struct RecordingStatusBar: View {
    @EnvironmentObject private var recorder: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform")
                    .foregroundStyle(recorder.isRecording ? .red : .secondary)
                    .accessibilityHidden(true)
                Text(recorder.statusText)
                    .lineLimit(1)
                if recorder.isRecording || recorder.isFinishing {
                    Text(recorder.formattedElapsedTime)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                RecordingActionButton()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

struct RecorderSettingsView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Form {
            Section("permissions.title") {
                RecordingPermissionsView()
            }
            Section("updates.title") {
                CheckForUpdatesButton(updater: updater, recorder: recorder)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 310)
        .task { await recorder.refreshPermissions() }
    }
}

private struct RecordingPermissionsView: View {
    @EnvironmentObject private var recorder: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                systemPermissionBadge
                PermissionBadge(title: "source.microphone", isGranted: recorder.hasMicrophonePermission)
            }

            if !recorder.hasAllPermissions {
                Text(permissionHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("permissions.grant") {
                        Task { await recorder.requestPermissions() }
                    }
                    .disabled(recorder.screenAccess == .checking)

                    Button("permissions.open_settings") {
                        recorder.openPrivacySettings()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var systemPermissionBadge: some View {
        switch recorder.screenAccess {
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("permissions.checking")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .unavailable:
            Label("permissions.check_failed", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsAuthorization:
            Label("permissions.needs_authorization", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.orange)
        case .granted, .denied:
            PermissionBadge(title: "source.system_audio", isGranted: recorder.hasScreenPermission)
        }
    }

    private var permissionHelp: String {
        switch recorder.screenAccess {
        case .checking: String(localized: "permissions.checking_help")
        case .needsAuthorization: String(localized: "permissions.request_help")
        case .denied: String(localized: "error.permission.screen_denied")
        case .unavailable(let detail): detail
        case .granted: String(localized: "permissions.help")
        }
    }
}

private struct PermissionBadge: View {
    let title: LocalizedStringKey
    let isGranted: Bool

    var body: some View {
        Label(title, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(isGranted ? .green : .orange)
            .font(.caption.weight(.medium))
    }
}

private struct InputWaveforms: View {
    @EnvironmentObject private var recorder: RecorderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: [Sample] = []
    @State private var lastSampleTime: ContinuousClock.Instant?

    private static let sampleInterval = Duration.milliseconds(60)

    private struct Sample {
        var system = 0.0
        var microphone = 0.0
    }

    private var isActive: Bool { recorder.isMonitoring || recorder.isRecording }

    var body: some View {
        let isScrolling = isActive && !reduceMotion
        let systemLevels = isActive ? history.map(\.system) : []
        let microphoneLevels = isActive ? history.map(\.microphone) : []

        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isScrolling)) { _ in
            let progress = isScrolling ? lastSampleTime.map {
                min(1, $0.duration(to: .now) / Self.sampleInterval)
            } : nil

            VStack(spacing: 16) {
                WaveformRow(title: "source.system_audio", icon: "macbook", levels: systemLevels,
                            scrollProgress: progress, reduceMotion: reduceMotion)
                WaveformRow(title: "source.microphone", icon: "mic", levels: microphoneLevels,
                            scrollProgress: progress, reduceMotion: reduceMotion)
            }
        }
        .task(id: recorder.state) {
            history.removeAll(keepingCapacity: true)
            lastSampleTime = nil
            guard isActive else { return }
            try? await collectLevels()
        }
    }

    private func collectLevels() async throws {
        // Keep the loudest measurement in each interval, even when a source
        // sends several buffers or sends no buffers at all.
        var peak = Sample()
        let systemLevels = recorder.$systemLevel.dropFirst().sink { level in
            peak.system = max(peak.system, level)
        }
        let microphoneLevels = recorder.$microphoneLevel.dropFirst().sink { level in
            peak.microphone = max(peak.microphone, level)
        }
        defer {
            systemLevels.cancel()
            microphoneLevels.cancel()
        }

        while !Task.isCancelled {
            try await Task.sleep(for: Self.sampleInterval)
            if history.count == WaveformRow.sampleCount + 1 {
                history.removeFirst()
            }
            history.append(peak)
            lastSampleTime = .now
            peak = Sample()
        }
    }
}

private struct WaveformRow: View {
    static let sampleCount = 48
    // The recorder maps -60...0 dBFS to 0...1, so 0.25 is -45 dBFS.
    private static let displayThreshold = 0.25

    let title: LocalizedStringKey
    let icon: String
    let levels: [Double]
    let scrollProgress: Double?
    let reduceMotion: Bool

    private var currentLevel: Double { levels.last ?? 0 }

    private func visibleAmplitude(for level: Double) -> Double {
        max(0, level - Self.displayThreshold) / (1 - Self.displayThreshold)
    }

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
                .labelStyle(AlignedIconLabelStyle())
                .font(.callout)
                .frame(width: 112, alignment: .leading)

            Canvas { context, size in
                let spacing = size.width / CGFloat(Self.sampleCount)
                let barWidth = spacing * 0.5
                let offset = CGFloat(scrollProgress ?? 0) * spacing
                // The extra sample slides in from beyond the right edge.
                let barCount = Self.sampleCount + (scrollProgress == nil ? 0 : 1)
                let litCount = Int((visibleAmplitude(for: currentLevel) * Double(Self.sampleCount)).rounded(.up))

                for index in 0..<barCount {
                    let sampleIndex = levels.count + index - barCount
                    let level = sampleIndex < 0 ? 0 : levels[sampleIndex]
                    let amplitude = visibleAmplitude(for: level)
                    let hasSignal = reduceMotion ? index < litCount : amplitude > 0

                    let height = reduceMotion ? 6 : 2 + CGFloat(amplitude) * (size.height - 2)
                    let color = hasSignal ? Color.blue : Color.secondary.opacity(0.35)
                    let bar = CGRect(x: (CGFloat(index) + 0.5) * spacing - barWidth / 2 - offset,
                                     y: (size.height - height) / 2,
                                     width: barWidth, height: height)
                    let cornerRadius = min(barWidth, height) / 2
                    context.fill(Path(roundedRect: bar, cornerRadius: cornerRadius), with: .color(color))
                }
            }
            .frame(height: 40)
            .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(currentLevel, format: .percent.precision(.fractionLength(0))))
    }
}

private struct AlignedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .frame(width: 24)
            configuration.title
        }
    }
}
