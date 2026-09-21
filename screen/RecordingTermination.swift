import Foundation

@MainActor
final class RecordingTermination {
    enum Decision { case now, later }
    private var pending = false

    func request(
        isBusy: Bool,
        prepare: @escaping () async -> Bool,
        reply: @escaping (Bool) -> Void
    ) -> Decision {
        guard !pending else { return .later }
        guard isBusy else { return .now }
        pending = true
        Task {
            let saved = await prepare()
            pending = false
            reply(saved)
        }
        return .later
    }
}
