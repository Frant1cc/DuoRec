import AVFoundation
import AppKit
import SwiftUI

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case recording
    case transcription

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .recording: "navigation.recording"
        case .transcription: "navigation.transcription"
        }
    }

    var icon: String {
        switch self {
        case .recording: "waveform"
        case .transcription: "doc.text"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var transcription = TranscriptionModel()
    @State private var selection: WorkspaceSection? = .recording
    @State private var columnVisibility = NavigationSplitViewVisibility.all

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
                    TranscriptionView(model: transcription)
                }
            }
            .navigationTitle((selection ?? .recording).title)
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if recorder.state != .idle {
                RecordingStatusBar()
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await recorder.recoverInterruptedRecordings()
            recorder.refreshMicrophones()
            await recorder.refreshPermissions()
        }
        .onDisappear { transcription.cancel() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            recorder.refreshMicrophones()
            Task { await recorder.refreshPermissions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(recorder.statusText)
                        .font(.title2.weight(.semibold))
                    Text("recording.subtitle")
                        .foregroundStyle(.secondary)
                }

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
                    if recorder.state == .idle {
                        RecordingActionButton()
                            .controlSize(.large)
                    }

                    Text("recording.headphones_tip")
                        .font(.callout)
                        .foregroundStyle(.secondary)

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
                LevelRow(title: "source.system_audio", icon: "macbook", level: recorder.systemLevel)
                LevelRow(title: "source.microphone", icon: "mic", level: recorder.microphoneLevel)
                Text(meterHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .disabled(recorder.isTransitioning || recorder.isRecording)
            }
        }
    }

    private var meterHelpText: LocalizedStringKey {
        if recorder.isRecording { return "levels.help.recording" }
        if recorder.isMonitoring { return "levels.help.monitoring" }
        return "levels.help.idle"
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
            .disabled(recorder.isBusy)
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
        case .granted, .denied:
            PermissionBadge(title: "source.system_audio", isGranted: recorder.hasScreenPermission)
        }
    }

    private var permissionHelp: String {
        switch recorder.screenAccess {
        case .checking: String(localized: "permissions.checking_help")
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

private struct LevelRow: View {
    let title: LocalizedStringKey
    let icon: String
    let level: Double

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
                .labelStyle(AlignedIconLabelStyle())
                .font(.callout)
                .frame(width: 112, alignment: .leading)

            ProgressView(value: level, total: 1)
                .tint(level > 0.82 ? .orange : .accentColor)
                .accessibilityLabel(Text(title))
        }
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
