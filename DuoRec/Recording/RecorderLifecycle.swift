// Capture and application availability are separate: quitting must be able to
// wait for an in-flight capture transition without allowing another operation.
struct RecorderLifecycle: Equatable {
    enum Capture: CaseIterable {
        case idle
        case startingRecording
        case startingMonitoring
        case stoppingMonitoring
        case monitoring
        case recording
        case saving
        case recovering

        var isPreparing: Bool {
            switch self {
            case .startingRecording, .startingMonitoring, .stoppingMonitoring: true
            default: false
            }
        }

        var isFinishing: Bool { self == .saving || self == .recovering }
        var acceptsLevels: Bool {
            self == .startingRecording || self == .startingMonitoring
                || self == .recording || self == .monitoring
        }
    }

    enum Availability: CaseIterable {
        case available
        case updating
        case terminating
    }

    var capture: Capture = .idle
    var availability: Availability = .available

    var canStartRecording: Bool {
        availability == .available && (capture == .idle || capture == .monitoring)
    }
    var canToggleMonitoring: Bool { canStartRecording }
    var canPerformPrimaryAction: Bool {
        canStartRecording || (availability == .available && capture == .recording)
    }
    var canEditSettings: Bool { availability == .available && capture == .idle }
    var canRecover: Bool { canEditSettings }
    var canCheckForUpdates: Bool { canEditSettings }
    var isBusy: Bool { capture != .idle || availability == .terminating }

    // Sparkle can publish the end of its cycle while termination is saving.
    // Only an update session may release the update lock.
    mutating func updateSessionChanged(isActive: Bool) {
        if isActive {
            guard canCheckForUpdates else { return }
            availability = .updating
        } else if availability == .updating {
            availability = .available
        }
    }
}
