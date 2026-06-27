import Foundation

public struct WatchPendingRecordingSession: Sendable, Equatable {
    public let sessionID: String
    public let fileURLs: [URL]
}

public enum WatchPendingRecordingStore {
    private static let syncedMarkerExtension = "synced"

    public static func pendingSessions() -> [WatchPendingRecordingSession] {
        groupedRecordingFiles(includeSyncedFiles: false)
            .map { sessionID, files in
                WatchPendingRecordingSession(
                    sessionID: sessionID,
                    fileURLs: files.sorted { $0.lastPathComponent < $1.lastPathComponent }
                )
            }
            .sorted { $0.sessionID > $1.sessionID }
    }

    public static func markFileSynced(_ fileURL: URL) {
        guard sessionID(from: fileURL) != nil else { return }

        let markerURL = syncedMarkerURL(for: fileURL)
        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
    }

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

    public static func trimStoredSessions(retainingLast retainedSessionLimit: Int = 10) {
        guard retainedSessionLimit > 0 else { return }

        let sessions = groupedRecordingFiles(includeSyncedFiles: true)
            .sorted { $0.key > $1.key }
        let sessionsToDelete = sessions.dropFirst(retainedSessionLimit)

        for (_, files) in sessionsToDelete {
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: syncedMarkerURL(for: fileURL))
            }
        }
    }

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
        let fileName = fileURL.lastPathComponent

        if fileName.hasPrefix("recording_"), fileName.hasSuffix(".watch.json") {
            return String(fileName.dropFirst("recording_".count).dropLast(".watch.json".count))
        }

        guard fileName.hasPrefix("recording_") else { return nil }

        let supportedExtensions = ["csv", "m4a"]
        guard supportedExtensions.contains(fileURL.pathExtension) else { return nil }

        return String(fileURL.deletingPathExtension().lastPathComponent.dropFirst("recording_".count))
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
