import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class RecordingPreview {
    private(set) var recording: SavedRecording?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    var error: String?

    private var player: AVPlayer?
    private var scopedFolder: URL?
    private var pendingSeek: UUID?

    func toggle(_ recording: SavedRecording, in folder: URL) {
        if self.recording?.id != recording.id {
            load(recording, in: folder)
        }

        guard let player else { return }
        if isPlaying {
            updatePosition()
            player.pause()
            isPlaying = false
        } else {
            if position >= recording.duration { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func didRename(from previous: URL, to renamed: SavedRecording, in folder: URL) {
        guard recording?.id == previous else { return }
        let wasPlaying = isPlaying
        let elapsed = position
        load(renamed, in: folder)
        seek(to: elapsed)
        if wasPlaying {
            player?.play()
            isPlaying = true
        }
    }

    private func load(_ recording: SavedRecording, in folder: URL) {
        stop()
        if folder.startAccessingSecurityScopedResource() { scopedFolder = folder }
        player = AVPlayer(url: recording.id)
        self.recording = recording
    }

    func seek(to seconds: TimeInterval) {
        guard let player, let recording else { return }
        position = min(max(seconds, 0), recording.duration)
        let time = CMTime(seconds: position, preferredTimescale: 600)
        let seekID = UUID()
        pendingSeek = seekID
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingSeek == seekID else { return }
                self.pendingSeek = nil
            }
        }
    }

    func updatePosition() {
        guard let player, let recording else { return }
        let item = player.currentItem
        if item?.status == .failed || player.status == .failed {
            error = (item?.error ?? player.error)?.localizedDescription
                ?? String(localized: "recordings.playback.error")
            stop()
            return
        }

        let seconds = player.currentTime().seconds
        if pendingSeek == nil, seconds.isFinite {
            position = min(max(seconds, 0), recording.duration)
        }
    }

    func finished(_ item: AVPlayerItem) {
        guard player?.currentItem === item, let recording else { return }
        isPlaying = false
        position = recording.duration
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        pendingSeek = nil
        if let scopedFolder { scopedFolder.stopAccessingSecurityScopedResource() }
        scopedFolder = nil
        isPlaying = false
        recording = nil
        position = 0
    }
}
