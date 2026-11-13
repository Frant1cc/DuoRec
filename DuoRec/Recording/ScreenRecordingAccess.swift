import Foundation
@preconcurrency import ScreenCaptureKit

enum ScreenRecordingAccess: Equatable, Sendable {
    case checking
    case needsAuthorization
    case granted
    case denied
    case unavailable(String)

    static func isPermissionDenial(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain
            && error.code == SCStreamError.Code.userDeclined.rawValue
    }

    @MainActor
    static func check(using probe: () async throws -> Void) async -> ScreenRecordingAccess {
        do {
            try await probe()
            return .granted
        } catch {
            if isPermissionDenial(error) { return .denied }
            let detail = error as NSError
            return .unavailable("\(detail.localizedDescription) (\(detail.domain), \(detail.code))")
        }
    }
}
