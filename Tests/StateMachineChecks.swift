import Foundation

@MainActor
private final class SourceProbe {
    let arrivals: AsyncStream<String>
    private let arrivalSignal: AsyncStream<String>.Continuation
    private var pending: [String: CheckedContinuation<URL?, Error>] = [:]

    init() {
        (arrivals, arrivalSignal) = AsyncStream.makeStream()
    }

    // Deliberately ignores cancellation, like an in-flight framework request.
    func resolve(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            pending[url.lastPathComponent] = continuation
            arrivalSignal.yield(url.lastPathComponent)
        }
    }

    func complete(_ name: String, with result: Result<URL?, Error>) {
        pending.removeValue(forKey: name)!.resume(with: result)
    }
}

private enum ProbeError: Error { case unreadable }

@main
struct StateMachineChecks {
    @MainActor
    static func main() async {
        checkActionPolicies()
        await checkModelGuards()
        await checkTranscriptionCancellation()
        await checkTermination()
        print("PASS: all state machine regression checks")
    }

    static func checkActionPolicies() {
        for availability in RecorderLifecycle.Availability.allCases {
            for capture in RecorderLifecycle.Capture.allCases {
                var lifecycle = RecorderLifecycle(capture: capture, availability: availability)
                let available = availability == .available
                let idle = capture == .idle
                let canStart = available && (idle || capture == .monitoring)
                precondition(lifecycle.canStartRecording == canStart)
                precondition(lifecycle.canToggleMonitoring == canStart)
                precondition(lifecycle.canPerformPrimaryAction == (canStart || (available && capture == .recording)))
                precondition(lifecycle.canEditSettings == (available && idle))
                precondition(lifecycle.canRecover == (available && idle))
                precondition(lifecycle.canCheckForUpdates == (available && idle))
                precondition(lifecycle.isBusy == (!idle || availability == .terminating))

                lifecycle.updateSessionChanged(isActive: true)
                let expected = available && idle ? .updating : availability
                precondition(lifecycle.availability == expected, "Update stole a busy capture or quit lock")
                lifecycle.updateSessionChanged(isActive: false)
                precondition(lifecycle.availability == (expected == .updating ? .available : expected))
            }
        }
        precondition(!RecorderLifecycle.Capture.stoppingMonitoring.acceptsLevels)
        precondition(!RecorderLifecycle.Capture.saving.acceptsLevels)
        precondition(!RecorderLifecycle.Capture.recovering.acceptsLevels)
        print("PASS: action permissions for all 24 capture/availability combinations")
    }

    @MainActor
    static func checkModelGuards() async {
        let recorder = RecorderModel()
        recorder.updateSessionChanged(isActive: true)
        precondition(recorder.isUpdateSessionActive && recorder.isTransitioning)
        await recorder.startRecording()
        await recorder.toggleInputMonitoring()
        await recorder.recoverInterruptedRecordings()
        recorder.chooseOutputFolder() // Must return before presenting a panel.
        precondition(recorder.state == .idle && !recorder.isMonitoring)
        precondition(recorder.screenAccess == .checking && recorder.errorMessage == nil)
        recorder.updateSessionChanged(isActive: false)
        precondition(recorder.canCheckForUpdates && recorder.canEditSettings)

        let saved = await recorder.prepareForTermination()
        precondition(saved && recorder.isTerminating)
        recorder.updateSessionChanged(isActive: true)
        recorder.updateSessionChanged(isActive: false)
        precondition(recorder.isTerminating, "Late update completion unlocked quitting")
        await recorder.startRecording()
        await recorder.toggleInputMonitoring()
        await recorder.recoverInterruptedRecordings()
        precondition(recorder.state == .idle && recorder.screenAccess == .checking)
        print("PASS: model entry points block capture/recovery/settings during updates and quitting")
    }

    @MainActor
    static func checkTranscriptionCancellation() async {
        let probe = SourceProbe()
        var arrivals = probe.arrivals.makeAsyncIterator()
        let model = TranscriptionModel(sourceResolver: probe.resolve)
        let folder = FileManager.default.temporaryDirectory
        let firstURL = folder.appendingPathComponent("first.mov")
        let secondURL = folder.appendingPathComponent("second.mp4")

        let first = model.transcribe(url: firstURL, outputFolderURL: folder)!
        let firstDocumentID = model.documentID
        let firstArrival = await arrivals.next()
        precondition(firstArrival == "first.mov")
        precondition(model.phase == .preparing && model.isWorking)
        precondition(model.transcribe(url: secondURL, outputFolderURL: folder) == nil,
                     "Repeated imports replaced an active operation")
        model.cancel()
        precondition(model.phase == .idle && model.fileName == nil && model.text.isEmpty)
        let second = model.transcribe(url: secondURL, outputFolderURL: folder)!
        precondition(model.documentID != firstDocumentID)
        let secondArrival = await arrivals.next()
        precondition(secondArrival == "second.mp4")

        // An older dual-track inspection finishes during a newer import.
        probe.complete("first.mov", with: .success(firstURL))
        await first.value
        precondition(model.phase == .preparing && model.fileName == "second.mp4")
        precondition(!model.usesSourceTimeline && model.segments.isEmpty && model.errorMessage == nil,
                     "Cancelled inspection changed the new import")

        probe.complete("second.mp4", with: .failure(ProbeError.unreadable))
        await second.value
        precondition(model.phase == .failed && !model.isWorking && model.errorMessage != nil)

        // A cancelled ordinary-file inspection must not create a speech analyzer.
        let third = model.transcribe(url: firstURL, outputFolderURL: folder)!
        _ = await arrivals.next()
        model.cancel()
        probe.complete("first.mov", with: .success(nil))
        await third.value
        precondition(model.phase == .idle && model.fileName == nil && model.errorMessage == nil)

        // Importing the same filename still invalidates selection/copy feedback.
        let previousDocumentID = model.documentID
        let fourth = model.transcribe(url: firstURL, outputFolderURL: folder)!
        _ = await arrivals.next()
        precondition(model.documentID != previousDocumentID)
        model.cancel()
        probe.complete("first.mov", with: .failure(ProbeError.unreadable))
        await fourth.value
        precondition(model.phase == .idle && model.errorMessage == nil)
        print("PASS: cancellation/reimport rejects stale dual-track and ordinary-file completions; failure is explicit")
    }

    @MainActor
    static func checkTermination() async {
        let termination = RecordingTermination()
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let (completed, completeSignal) = AsyncStream<Bool>.makeStream()
        var saves = 0
        let prepare: () async -> Bool = {
            saves += 1
            startSignal.yield(())
            for await _ in release { break }
            return false
        }
        let reply: (Bool) -> Void = { completeSignal.yield($0) }
        precondition(termination.request(isBusy: true, prepare: prepare, reply: reply) == .later)
        for await _ in started { break }
        precondition(termination.request(isBusy: true, prepare: prepare, reply: reply) == .later)
        precondition(saves == 1)
        releaseSignal.yield(())
        for await saved in completed {
            precondition(!saved, "Failed save must cancel quitting")
            break
        }
        precondition(termination.request(isBusy: false, prepare: prepare, reply: reply) == .now)
        print("PASS: repeated quit shares preparation; failed save cancels quit and permits retry")
    }
}
