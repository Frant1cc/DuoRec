import Foundation

enum RecordingFinalizer {
    // ScreenCaptureKit can report an already stopped stream. Its stop result
    // must never prevent the writer from sealing the samples it has received.
    static func finish(
        stopping: () async throws -> Void,
        finishing: () async throws -> URL
    ) async throws -> URL {
        do { try await stopping() } catch { /* Still finalize recorded audio. */ }
        return try await finishing()
    }
}
