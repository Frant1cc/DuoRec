import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    private weak var recorder: RecorderModel?
    private var controller: SPUStandardUpdaterController?
    private var sessionObservation: AnyCancellable?

    func attach(to recorder: RecorderModel) {
        guard controller == nil else { return }
        self.recorder = recorder
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        sessionObservation = controller.updater.publisher(for: \.sessionInProgress)
            .sink { [weak recorder] active in recorder?.isUpdateSessionActive = active }

        // Unconfigured source builds can still record; they cannot accept updates.
        if let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           Data(base64Encoded: key)?.count == 32 {
            controller.startUpdater()
        }
    }

    func checkForUpdates() {
        guard let recorder, !recorder.isBusy, !recorder.isUpdateSessionActive,
              let controller, canCheckForUpdates else { return }
        // Lock synchronously, before Sparkle publishes its session state.
        recorder.isUpdateSessionActive = true
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard let recorder, !recorder.isBusy else {
            throw NSError(domain: "frant1c.duorec.updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "updates.busy")
            ])
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        recorder?.isUpdateSessionActive = false
    }
}
