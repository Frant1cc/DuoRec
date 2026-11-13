import Foundation
import ScreenCaptureKit

@MainActor
private final class PermissionProbe {
    let arrivals: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Void, Error>?
    private(set) var calls = 0

    init() { (arrivals, signal) = AsyncStream.makeStream() }

    func check() async throws {
        calls += 1
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil, "Permission requests overlapped")
            pending = continuation
            signal.yield(())
        }
    }

    func complete(_ result: Result<Void, Error>) {
        let continuation = pending!
        pending = nil
        continuation.resume(with: result)
    }
}

@main
struct PermissionChecks {
    @MainActor
    static func main() async {
        let probe = PermissionProbe()
        var arrivals = probe.arrivals.makeAsyncIterator()
        var preflightGranted = false
        let recorder = RecorderModel(screenCapturePreflight: { preflightGranted },
                                     screenPermissionProbe: probe.check)

        // Main-window task, activation notifications, and settings appearance
        // must remain passive even if they run sequentially after a denial.
        for _ in 0..<5 { await recorder.refreshPermissions() }
        precondition(probe.calls == 0 && recorder.screenAccess == .needsAuthorization)

        let first = Task { await recorder.requestScreenPermission() }
        _ = await arrivals.next()
        precondition(recorder.screenAccess == .checking && probe.calls == 1)
        for _ in 0..<3 { await recorder.refreshPermissions() }
        precondition(recorder.screenAccess == .checking && probe.calls == 1)

        let (joined, joinSignal) = AsyncStream<Void>.makeStream()
        let second = Task {
            joinSignal.yield(())
            await recorder.requestScreenPermission()
        }
        for await _ in joined { break }
        precondition(probe.calls == 1)
        probe.complete(.success(()))
        await first.value
        await second.value
        precondition(recorder.screenAccess == .granted && probe.calls == 1)

        // CoreGraphics can disagree with ScreenCaptureKit. Its negative hint
        // must not revoke a verified grant or block the actual capture path.
        await recorder.refreshPermissions()
        precondition(recorder.screenAccess == .granted && probe.calls == 1)

        let revoked = Task { await recorder.requestScreenPermission() }
        _ = await arrivals.next()
        probe.complete(.failure(NSError(domain: SCStreamErrorDomain, code: -3801)))
        await revoked.value
        for _ in 0..<5 { await recorder.refreshPermissions() }
        precondition(recorder.screenAccess == .denied && probe.calls == 2,
                     "Dismissing a denial caused another permission request")

        preflightGranted = true
        await recorder.refreshPermissions()
        precondition(recorder.screenAccess == .granted && probe.calls == 2)

        let unavailable = Task { await recorder.requestScreenPermission() }
        _ = await arrivals.next()
        probe.complete(.failure(NSError(domain: SCStreamErrorDomain, code: -3811)))
        await unavailable.value
        guard case .unavailable = recorder.screenAccess else { fatalError("Misclassified framework failure") }
        preflightGranted = false
        await recorder.refreshPermissions()
        precondition(probe.calls == 3)

        recorder.updateSessionChanged(isActive: true)
        await recorder.requestScreenPermission()
        precondition(probe.calls == 3, "An update started a permission request")
        print("PASS: passive startup/activation/settings, coalesced explicit requests, denial without re-prompts, verified grants and framework errors")
    }
}
