import SwiftUI

@main
struct DuoRecApp: App {
    @NSApplicationDelegateAdaptor(RecorderApplicationDelegate.self) private var appDelegate
    @StateObject private var recorder = RecorderModel()

    var body: some Scene {
        WindowGroup("DuoRec") {
            ContentView()
                .environmentObject(recorder)
                .onAppear { appDelegate.recorder = recorder }
        }
        .windowResizability(.contentSize)

        Window("transcription.title", id: "transcription") {
            TranscriptionView()
                .environmentObject(recorder)
        }
        .defaultSize(width: 720, height: 560)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarRecorderView()
                .environmentObject(recorder)
                .onAppear { appDelegate.recorder = recorder }
        } label: {
            if recorder.isRecording {
                Label {
                    Text(recorder.formattedElapsedTime)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.multicolor)
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
                Image(nsImage: MenuBarArtwork.ready)
                    .accessibilityLabel(String(localized: "menu.ready_accessibility"))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

private enum MenuBarArtwork {
    static let ready: NSImage = {
        // Size the image handed to the native status item in points. A SwiftUI
        // frame alone doesn't set its intrinsic size when the display changes.
        let image = (NSImage(named: "DuoRecMark")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class RecorderApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: RecorderModel?
    private let termination = RecordingTermination()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder else { return .terminateNow }
        let decision = termination.request(
            isBusy: recorder.isBusy,
            prepare: { await recorder.prepareForTermination() },
            reply: { saved in
                sender.reply(toApplicationShouldTerminate: saved)
                if !saved {
                    sender.activate(ignoringOtherApps: true)
                    sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
            }
        )
        return decision == .later ? .terminateLater : .terminateNow
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
