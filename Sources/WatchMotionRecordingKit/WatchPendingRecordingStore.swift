import Foundation

/// Locally retained files that share one recording session UUID.
public struct WatchPendingRecordingSession: Sendable, Equatable {
    public let sessionID: String
    public let fileURLs: [URL]
}

/// Tracks background transfer completion without deleting recordings immediately.
///
/// Every successfully transferred file receives a small hidden marker. A session
/// remains pending while any of its files lacks that marker. Retention cleanup is
/// session-based so related motion, metadata, audio, and video assets stay together.
public enum WatchPendingRecordingStore {
    private static let syncedMarkerExtension = "synced"

    /// Returns newest-first sessions containing at least one unmarked file.
    public static func pendingSessions() -> [WatchPendingRecordingSession] {
        groupedRecordingFiles(includeSyncedFiles: false)
            .map { sessionID, files in
                WatchPendingRecordingSession(
                    sessionID: sessionID,
                    fileURLs: files.sorted { $0.lastPathComponent < $1.lastPathComponent }
                )
            }
            .sorted { latestFileDate(in: $0.fileURLs) > latestFileDate(in: $1.fileURLs) }
    }

    /// Records successful transfer of one file by creating its hidden marker.
    public static func markFileSynced(_ fileURL: URL) {
        guard sessionID(from: fileURL) != nil else { return }

        let markerURL = syncedMarkerURL(for: fileURL)
        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
    }

    /// Removes transfer markers so retained files can all be queued again.
    public static func resetSyncMarkers() {
        let directoryURL = recordingsDirectoryURL()
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }

        for fileURL in files where isSyncMarker(fileURL) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// Deletes whole older sessions after retaining the requested newest sessions.
    public static func trimStoredSessions(retainingLast retainedSessionLimit: Int = 10) {
        guard retainedSessionLimit > 0 else { return }

        let sessions = groupedRecordingFiles(includeSyncedFiles: true)
            .sorted { latestFileDate(in: $0.value) > latestFileDate(in: $1.value) }
        let sessionsToDelete = sessions.dropFirst(retainedSessionLimit)

        for (_, files) in sessionsToDelete {
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: syncedMarkerURL(for: fileURL))
            }
        }
    }

    /// Directory containing recording assets and their hidden transfer markers.
    public static func recordingsDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func groupedRecordingFiles(includeSyncedFiles: Bool) -> [String: [URL]] {
        let directoryURL = recordingsDirectoryURL()
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return [:]
        }

        var groupedFiles: [String: [URL]] = [:]

        for fileURL in files {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard !isSyncMarker(fileURL) else { continue }
            guard includeSyncedFiles || !isFileSynced(fileURL) else { continue }
            guard let sessionID = sessionID(from: fileURL) else { continue }
            groupedFiles[sessionID, default: []].append(fileURL)
        }

        return groupedFiles
    }

    private static func sessionID(from fileURL: URL) -> String? {
        WatchRecordingAssetNaming.sessionID(from: fileURL.lastPathComponent)
    }

    private static func latestFileDate(in fileURLs: [URL]) -> Date {
        fileURLs.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return values?.contentModificationDate ?? values?.creationDate
        }
        .max() ?? .distantPast
    }

    private static func isFileSynced(_ fileURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: syncedMarkerURL(for: fileURL).path)
    }

    private static func syncedMarkerURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(syncedMarkerExtension)")
    }

    private static func isSyncMarker(_ fileURL: URL) -> Bool {
        fileURL.lastPathComponent.hasPrefix(".") && fileURL.pathExtension == syncedMarkerExtension
    }
}
