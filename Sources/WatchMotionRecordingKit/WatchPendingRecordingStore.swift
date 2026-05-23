import Foundation

public struct WatchPendingRecordingSession: Sendable, Equatable {
    public let sessionID: String
    public let fileURLs: [URL]
}

public enum WatchPendingRecordingStore {
    public static func pendingSessions() -> [WatchPendingRecordingSession] {
        let directoryURL = recordingsDirectoryURL()
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var groupedFiles: [String: [URL]] = [:]

        for fileURL in files {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let sessionID = sessionID(from: fileURL) else { continue }
            groupedFiles[sessionID, default: []].append(fileURL)
        }

        return groupedFiles
            .filter { _, files in files.contains { $0.pathExtension == "csv" } }
            .map { sessionID, files in
                WatchPendingRecordingSession(
                    sessionID: sessionID,
                    fileURLs: files.sorted { $0.lastPathComponent < $1.lastPathComponent }
                )
            }
            .sorted { $0.sessionID > $1.sessionID }
    }

    public static func recordingsDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
}
