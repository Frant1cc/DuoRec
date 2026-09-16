import SwiftUI

@main
struct DuoRecApp: App {
    @StateObject private var recorder = RecorderModel()

    var body: some Scene {
        WindowGroup("DuoRec") {
            ContentView()
                .environmentObject(recorder)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarRecorderView()
                .environmentObject(recorder)
        } label: {
            if recorder.isRecording {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text(recorder.formattedElapsedTime)
                        .monospacedDigit()
                }
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(
                        format: String(localized: "menu.recording_accessibility"),
                        recorder.formattedElapsedTime
                    )
                )
            } else if recorder.isPreparing || recorder.isFinishing {
                Image(systemName: "hourglass")
                    .accessibilityLabel(recorder.statusText)
            } else {
                Image("DuoRecMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(String(localized: "menu.ready_accessibility"))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarRecorderView: View {
    @EnvironmentObject private var recorder: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DuoRec")
                        .font(.headline)
                    Text(recorder.isRecording ? recorder.formattedElapsedTime : recorder.statusText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(recorder.isRecording ? .red : .secondary)
                }
                Spacer()
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 9, height: 9)
            }

            HStack(spacing: 10) {
                MiniLevel(icon: "macbook", level: recorder.systemLevel)
                MiniLevel(icon: "mic", level: recorder.microphoneLevel)
            }

            Button(recorder.primaryActionTitle) {
                Task {
                    if recorder.isRecording {
                        await recorder.stopRecording()
                    } else {
                        await recorder.startRecording()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .frame(maxWidth: .infinity)
            .disabled(recorder.isTransitioning)

            if let lastRecordingURL = recorder.lastRecordingURL {
                Button("recording.reveal") {
                    recorder.reveal(lastRecordingURL)
                }
                .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

private struct MiniLevel: View {
    let icon: String
    let level: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            ProgressView(value: level)
                .progressViewStyle(.linear)
        }
    }
}
