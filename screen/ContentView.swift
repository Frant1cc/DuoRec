import AVFoundation
import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: RecorderModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                    .padding(.vertical, 16)
                permissionSection
                meterSection
                    .padding(.top, 18)
                settingsSection
                    .padding(.top, 18)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer(minLength: 12)
            Divider()
            actionSection
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.bar)
        }
        .frame(width: 460, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            recorder.refreshMicrophones()
            await recorder.refreshPermissions()
        }
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
        } message: {
            Text(recorder.errorMessage ?? String(localized: "error.unknown"))
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 5) {
                Text("DuoRec")
                    .font(.title2.weight(.semibold))
                Text(recorder.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if recorder.isRecording {
                Text(recorder.formattedElapsedTime)
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("permissions.title")
                    .font(.headline)
                Spacer()
                systemPermissionBadge
                PermissionBadge(title: "source.microphone", isGranted: recorder.hasMicrophonePermission)
            }

            if !recorder.hasAllPermissions {
                HStack {
                    Button("permissions.grant") {
                        Task { await recorder.requestPermissions() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.screenAccess == .checking)

                    Button("permissions.open_settings") {
                        recorder.openPrivacySettings()
                    }
                    .buttonStyle(.borderless)
                }
                Text(permissionHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("levels.title")
                    .font(.headline)
                Spacer()
                Button(recorder.isMonitoring ? "monitor.stop" : "monitor.start") {
                    Task { await recorder.toggleInputMonitoring() }
                }
                .buttonStyle(.borderless)
                .disabled(recorder.isTransitioning || recorder.isRecording)
            }
            LevelRow(title: "source.system_audio", icon: "macbook", level: recorder.systemLevel)
            LevelRow(title: "source.microphone", icon: "mic", level: recorder.microphoneLevel)
            Text(meterHelpText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var meterHelpText: LocalizedStringKey {
        if recorder.isRecording { return "levels.help.recording" }
        if recorder.isMonitoring { return "levels.help.monitoring" }
        return "levels.help.idle"
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.title")
                .font(.headline)

            HStack {
                Label("settings.microphone", systemImage: "mic")
                    .foregroundStyle(.secondary)
                Spacer()
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
                .frame(width: 230, alignment: .trailing)
                .disabled(recorder.isBusy)
            }

            HStack {
                Label("settings.microphone_boost", systemImage: "waveform.badge.plus")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("settings.microphone_boost", selection: $recorder.microphoneBoostDB) {
                    Text("common.off").tag(Float(0))
                    Text("+6 dB").tag(Float(6))
                    Text("+12 dB").tag(Float(12))
                }
                .labelsHidden()
                .frame(width: 230, alignment: .trailing)
                .disabled(recorder.isBusy)
            }

            HStack {
                Label("settings.save_location", systemImage: "folder")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    recorder.chooseOutputFolder()
                } label: {
                    HStack(spacing: 5) {
                        Text(recorder.outputFolderDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.borderless)
                .frame(width: 230, alignment: .trailing)
                .help(recorder.outputFolderURL.path)
                .disabled(recorder.isBusy)
            }
            .font(.callout)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    if recorder.isRecording {
                        await recorder.stopRecording()
                    } else {
                        await recorder.startRecording()
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    if recorder.isPreparing || recorder.isFinishing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                    }
                    Text(recorder.primaryActionTitle)
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(width: 240, height: 38)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .controlSize(.regular)
            .disabled(recorder.isTransitioning)

            if let lastRecordingURL = recorder.lastRecordingURL {
                Button("recording.reveal_recent") {
                    recorder.reveal(lastRecordingURL)
                }
                .buttonStyle(.link)
            } else {
                Text("recording.headphones_tip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionBadge: View {
    let title: LocalizedStringKey
    let isGranted: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
    }
}

private struct LevelRow: View {
    let title: LocalizedStringKey
    let icon: String
    let level: Double

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 24, alignment: .center)
                Text(title)
                    .frame(width: 64, alignment: .leading)
            }
            .font(.callout)
            .frame(width: 98, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(level > 0.82 ? Color.orange : Color.accentColor)
                        .frame(width: geometry.size.width * level)
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 8)
        }
    }
}
