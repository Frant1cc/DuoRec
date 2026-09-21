import Foundation
import ScreenCaptureKit

@main
struct PermissionChecks {
    @MainActor
    static func main() async {
        // An actual successful ScreenCaptureKit probe must grant access without
        // consulting or persisting a separate CoreGraphics preflight result.
        let granted = await ScreenRecordingAccess.check {}
        precondition(granted == .granted)

        let denied = await ScreenRecordingAccess.check {
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        }
        precondition(denied == .denied)

        // A framework outage must not tell the user they refused permission.
        let unavailable = await ScreenRecordingAccess.check {
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue)
        }
        guard case .unavailable(let detail) = unavailable else { fatalError("Misclassified framework failure") }
        precondition(detail.contains("-3811"))

        // The same numeric code from a different subsystem isn't a TCC denial.
        let unrelated = await ScreenRecordingAccess.check {
            throw NSError(domain: "OtherSubsystem", code: -3801)
        }
        guard case .unavailable = unrelated else { fatalError("Ignored error domain") }

        // Rechecking after revocation cannot reuse a previously granted result.
        var shouldDeny = false
        func probe() async throws {
            if shouldDeny { throw NSError(domain: SCStreamErrorDomain, code: -3801) }
        }
        let before = await ScreenRecordingAccess.check(using: probe)
        shouldDeny = true
        let after = await ScreenRecordingAccess.check(using: probe)
        precondition(before == .granted && after == .denied)
        print("PASS: granted, denied, unavailable, error domain, revocation")
    }
}
