import Foundation

@main
struct TerminationChecks {
    @MainActor
    static func main() async {
        let termination = RecordingTermination()
        var saves = 0
        var replies: [Bool] = []
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let (completed, completeSignal) = AsyncStream<Void>.makeStream()
        let prepare: () async -> Bool = {
            saves += 1
            startSignal.yield(())
            for await _ in release { break }
            return true
        }
        let reply: (Bool) -> Void = {
            replies.append($0)
            completeSignal.yield(())
        }
        precondition(termination.request(isBusy: false, prepare: prepare, reply: reply) == .now)
        precondition(saves == 0 && replies.isEmpty)
        precondition(termination.request(isBusy: true, prepare: prepare, reply: reply) == .later)
        for await _ in started { break }
        precondition(replies.isEmpty, "Quit replied before saving finished")
        precondition(termination.request(isBusy: true, prepare: prepare, reply: reply) == .later)
        precondition(saves == 1, "Duplicate quit started another save")
        releaseSignal.yield(())
        for await _ in completed { break }
        precondition(replies == [true])
        print("PASS: quit waits for save; repeated quit shares pending operation")

        let (failed, failedSignal) = AsyncStream<Void>.makeStream()
        precondition(termination.request(isBusy: true, prepare: { false }, reply: {
            replies.append($0)
            failedSignal.yield(())
        }) == .later)
        for await _ in failed { break }
        precondition(replies == [true, false], "Save failure must cancel termination")
        precondition(termination.request(isBusy: false, prepare: prepare, reply: reply) == .now)
        print("PASS: failed save cancels quit and a later idle quit is allowed")
    }
}
