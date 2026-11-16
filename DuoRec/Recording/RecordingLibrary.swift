import AVFoundation
import Darwin
import Foundation

nonisolated struct SavedRecording: Identifiable, Sendable {
    struct File: Equatable, Sendable {
        let url: URL
        let identifier: UInt64?
        let created: Date?
        let modified: Date?
        let byteCount: Int64

        init?(url: URL) throws {
            let values = try url.resourceValues(forKeys: Self.resourceKeys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize else { return nil }
            self.url = url
            identifier = values.fileIdentifier
            created = values.creationDate
            modified = values.contentModificationDate
            byteCount = Int64(size)
        }

        static let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileIdentifierKey,
            .creationDateKey, .contentModificationDateKey, .fileSizeKey
        ]

        var nameSuffix: String {
            url.lastPathComponent.hasSuffix(".tracks.mov") ? ".tracks.mov" : ".\(url.pathExtension)"
        }

        var isUnchanged: Bool {
            var address = url
            address.removeAllCachedResourceValues()
            return (try? File(url: address)) == self
        }
    }

    let file: File
    let companion: File?
    let name: String?
    let date: Date?
    let duration: TimeInterval

    var id: URL { file.url }
    var editableName: String { String(id.lastPathComponent.dropLast(file.nameSuffix.count)) }
    var files: [File] { [file] + [companion].compactMap { $0 } }
    var byteCount: Int64 { file.byteCount + (companion?.byteCount ?? 0) }
}

enum RecordingLibrary {
    nonisolated private static let dateAttribute = "frant1c.duorec.recording-date"

    @concurrent
    static func load(from folder: URL) async throws -> [SavedRecording] {
        let hasScope = folder.startAccessingSecurityScopedResource()
        defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(SavedRecording.File.resourceKeys),
                options: .skipsHiddenFiles
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }

        let files = urls.compactMap { url -> SavedRecording.File? in
            guard ["mp4", "m4a", "mov"].contains(url.pathExtension.lowercased()) else { return nil }
            return try? SavedRecording.File(url: url)
        }
        let filesByName = Dictionary(uniqueKeysWithValues: files.map { ($0.url.lastPathComponent, $0) })
        let legacyPairs = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (URL, SavedRecording.File)? in
            guard file.url.pathExtension.lowercased() == "m4a",
                  let companion = filesByName[AudioTrackExtractor.companionURL(for: file.url).lastPathComponent]
            else { return nil }
            return (file.url, companion)
        })
        let pairedCompanions = Set(legacyPairs.values.map(\.url))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let generatedName = #/^(\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}) DuoRec(?: - (Raw Tracks|原始双轨))?(?: (\d+))?$/#
        var recordings: [SavedRecording] = []

        // Fallback to the standalone source file if its paired M4A can't be read.
        for file in files where !pairedCompanions.contains(file.url) {
            try Task.checkCancellation()
            let companion = legacyPairs[file.url]
            if let recording = await entry(for: file, companion: companion, formatter: formatter, pattern: generatedName) {
                recordings.append(recording)
            } else if let companion,
                      let recording = await entry(for: companion, companion: nil, formatter: formatter, pattern: generatedName) {
                recordings.append(recording)
            }
        }

        return recordings.sorted { lhs, rhs in
            let leftDate = lhs.date ?? .distantPast
            let rightDate = rhs.date ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.id.lastPathComponent.localizedStandardCompare(rhs.id.lastPathComponent) == .orderedDescending
        }
    }

    @concurrent
    static func rename(_ recording: SavedRecording, to name: String, in folder: URL) async throws -> SavedRecording {
        guard !name.isEmpty, !name.hasPrefix("."),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:").union(.controlCharacters)) == nil
        else { throw RenameError.invalidName }

        let hasScope = folder.startAccessingSecurityScopedResource()
        defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }

        // Directory listing can resolve the sandbox's Downloads symlink.
        let resolvedFolder = folder.resolvingSymlinksInPath()
        let files = recording.files
        guard files.allSatisfy({
            $0.url.deletingLastPathComponent().resolvingSymlinksInPath() == resolvedFolder && $0.isUnchanged
        }) else { throw RenameError.changed }
        if name == recording.editableName { return recording }

        let destinations = files.map { resolvedFolder.appendingPathComponent(name + $0.nameSuffix) }
        // A standalone legacy file must not become paired with a different recording.
        if files.count == 1 {
            let siblingSuffix: String? = switch recording.file.nameSuffix.lowercased() {
            case ".m4a": ".tracks.mov"
            case ".tracks.mov": ".m4a"
            default: nil
            }
            if let siblingSuffix {
                let sibling = resolvedFolder.appendingPathComponent(name + siblingSuffix)
                var info = stat()
                if lstat(sibling.path, &info) == 0 { throw RenameError.nameInUse }
                if errno != ENOENT { throw posixError() }
            }
        }

        let date = recording.date.map { String($0.timeIntervalSinceReferenceDate) } ?? "unknown"
        let bytes = Array(date.utf8)
        for file in files {
            guard setxattr(file.url.path, dateAttribute, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 else {
                throw posixError()
            }
        }

        var moved: [(original: URL, destination: URL)] = []
        let renamed: [SavedRecording.File]
        do {
            for (file, destination) in zip(files, destinations) {
                try moveWithoutReplacing(file.url, to: destination)
                moved.append((file.url, destination))
            }
            renamed = try destinations.map { url in
                guard let file = try SavedRecording.File(url: url) else { throw RenameError.changed }
                return file
            }
        } catch {
            for file in moved.reversed() {
                do { try moveWithoutReplacing(file.destination, to: file.original) }
                catch { throw RenameError.restoreFailed }
            }
            throw error
        }
        return SavedRecording(file: renamed[0], companion: renamed.dropFirst().first,
                              name: name, date: recording.date, duration: recording.duration)
    }

    nonisolated private static func moveWithoutReplacing(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 else { return }
        let failure = errno
        if failure == EEXIST { throw RenameError.nameInUse }
        guard failure == ENOTSUP else { throw posixError(failure) }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch CocoaError.fileWriteFileExists {
            throw RenameError.nameInUse
        }
    }

    nonisolated private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    nonisolated private static func savedDate(at url: URL) -> String? {
        var bytes = [UInt8](repeating: 0, count: 64)
        let length = getxattr(url.path, dateAttribute, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        guard length > 0, let value = String(bytes: bytes.prefix(length), encoding: .utf8),
              value == "unknown" || Double(value)?.isFinite == true
        else { return nil }
        return value
    }

    nonisolated enum RenameError: LocalizedError {
        case invalidName, nameInUse, changed, restoreFailed

        var errorDescription: String? {
            switch self {
            case .invalidName: String(localized: "recordings.rename.invalid")
            case .nameInUse: String(localized: "recordings.rename.name_in_use")
            case .changed: String(localized: "recordings.rename.changed")
            case .restoreFailed: String(localized: "recordings.rename.restore_failed")
            }
        }
    }

    nonisolated private static func entry(
        for file: SavedRecording.File, companion: SavedRecording.File?, formatter: DateFormatter,
        pattern: Regex<(Substring, Substring, Substring?, Substring?)>
    ) async -> SavedRecording? {
        let isLegacySource = file.nameSuffix == ".tracks.mov"
        let name = String(file.url.lastPathComponent.dropLast(file.nameSuffix.count))
        let generated = name.wholeMatch(of: pattern)
        let storedDate = savedDate(at: file.url)
        let asset = AVURLAsset(url: file.url)

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { return nil }
            if storedDate == nil, generated == nil, companion == nil, !isLegacySource {
                let sources = try await AudioTrackExtractor.sourceTracks(in: file.url, asset: asset)
                guard !sources.isEmpty else { return nil }
            }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { return nil }
            let generatedDate = generated.flatMap { formatter.date(from: String($0.output.1)) }
            let originalDate = storedDate.flatMap { Double($0).map(Date.init(timeIntervalSinceReferenceDate:)) }
            let customName = generated == nil || generated?.output.2 != nil || generated?.output.3 != nil
                || (originalDate != nil && originalDate != generatedDate)
            return SavedRecording(
                file: file, companion: companion,
                name: customName ? name : nil,
                date: originalDate ?? generatedDate ?? file.created ?? file.modified,
                duration: duration
            )
        } catch {
            return nil
        }
    }
}
