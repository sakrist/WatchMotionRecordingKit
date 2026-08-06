import Foundation

/// The files that can appear at the root of a recording package.
public enum RecordingPackageAssetKind: String, CaseIterable, Codable, Sendable {
    case deviceMotion
    case rawAccelerometer
    case watchMetadata
    case audio
    case video
    case phoneMetadata

    /// Whether this asset is required for every recording package.
    public var isCoreAsset: Bool {
        switch self {
        case .deviceMotion, .rawAccelerometer, .watchMetadata:
            return true
        case .audio, .video, .phoneMetadata:
            return false
        }
    }
}

/// The package profiles understood by the recording tools.
public enum RecordingPackageProfile: String, Codable, Sendable {
    case core
    case extended
}

/// Errors raised before a consumer validates the contents of the binary files.
public enum RecordingPackageError: Error, Equatable, LocalizedError, Sendable {
    case packageIsNotDirectory
    case invalidPackageName(String)
    case unsupportedVisibleAsset(String)
    case nestedVisibleDirectory(String)
    case missingAsset(RecordingPackageAssetKind)
    case duplicateAsset(RecordingPackageAssetKind)
    case videoMetadataRequired
    case profileMismatch(expected: RecordingPackageProfile, actual: RecordingPackageProfile)

    public var errorDescription: String? {
        switch self {
        case .packageIsNotDirectory:
            return "The recording package is not a directory."
        case .invalidPackageName(let name):
            return "The recording package name is invalid: \(name)"
        case .unsupportedVisibleAsset(let name):
            return "The recording package contains an unsupported asset: \(name)"
        case .nestedVisibleDirectory(let name):
            return "The recording package contains a nested directory: \(name)"
        case .missingAsset(let kind):
            return "The recording package is missing its \(kind.rawValue) asset."
        case .duplicateAsset(let kind):
            return "The recording package contains duplicate \(kind.rawValue) assets."
        case .videoMetadataRequired:
            return "A recording package with video must include phone metadata."
        case .profileMismatch(let expected, let actual):
            return "Expected a \(expected.rawValue) package but found \(actual.rawValue) assets."
        }
    }
}

/// Canonical names and paths for one folder-based recording package.
public enum RecordingPackageLayout {
    public static let packageSuffix = ".recording"

    public static func packageDirectoryName(sessionID: String) -> String {
        WatchRecordingAssetNaming.baseName(sessionID: sessionID) + packageSuffix
    }

    public static func packageURL(in rootURL: URL, sessionID: String) -> URL {
        rootURL.appendingPathComponent(packageDirectoryName(sessionID: sessionID), isDirectory: true)
    }

    public static func assetFileName(
        _ kind: RecordingPackageAssetKind,
        sessionID: String
    ) -> String {
        switch kind {
        case .deviceMotion:
            return WatchRecordingAssetNaming.deviceMotionFileName(sessionID: sessionID)
        case .rawAccelerometer:
            return WatchRecordingAssetNaming.rawAccelerometerFileName(sessionID: sessionID)
        case .watchMetadata:
            return WatchRecordingAssetNaming.metadataFileName(sessionID: sessionID)
        case .audio:
            return WatchRecordingAssetNaming.audioFileName(sessionID: sessionID)
        case .video:
            return WatchRecordingAssetNaming.videoFileName(sessionID: sessionID)
        case .phoneMetadata:
            return WatchRecordingAssetNaming.phoneMetadataFileName(sessionID: sessionID)
        }
    }

    public static func assetURL(
        _ kind: RecordingPackageAssetKind,
        in packageURL: URL,
        sessionID: String
    ) -> URL {
        packageURL.appendingPathComponent(assetFileName(kind, sessionID: sessionID))
    }

    public static func sessionID(fromPackageDirectoryName name: String) -> String? {
        guard name.hasSuffix(packageSuffix) else { return nil }
        let baseName = String(name.dropLast(packageSuffix.count))
        let identifier = baseName
        return UUID(uuidString: identifier)?.uuidString.lowercased()
    }

    public static func assetKind(
        for fileName: String,
        sessionID: String
    ) -> RecordingPackageAssetKind? {
        RecordingPackageAssetKind.allCases.first { kind in
            assetFileName(kind, sessionID: sessionID) == fileName
        }
    }
}

/// A validated view of the files in one recording package directory.
///
/// This descriptor validates filesystem shape and identity. Consumers still
/// validate binary headers, hashes, sample counts, and JSON semantics using
/// their existing readers.
public struct RecordingPackageDescriptor: Equatable, Sendable {
    public let packageURL: URL
    public let sessionID: String
    public let profile: RecordingPackageProfile
    public let deviceMotionURL: URL
    public let rawAccelerometerURL: URL
    public let watchMetadataURL: URL
    public let audioURL: URL?
    public let videoURL: URL?
    public let phoneMetadataURL: URL?

    public init(
        packageURL: URL,
        expectedProfile: RecordingPackageProfile? = nil,
        fileManager: FileManager = .default
    ) throws {
        let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw RecordingPackageError.packageIsNotDirectory
        }

        guard let sessionID = RecordingPackageLayout.sessionID(fromPackageDirectoryName: packageURL.lastPathComponent) else {
            throw RecordingPackageError.invalidPackageName(packageURL.lastPathComponent)
        }

        var assets: [RecordingPackageAssetKind: URL] = [:]
        let children = try fileManager.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )

        for childURL in children {
            let name = childURL.lastPathComponent
            if name.hasPrefix(".") { continue }

            let childValues = try childURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if childValues.isDirectory == true {
                throw RecordingPackageError.nestedVisibleDirectory(name)
            }
            guard childValues.isRegularFile == true else {
                throw RecordingPackageError.unsupportedVisibleAsset(name)
            }
            guard let kind = RecordingPackageLayout.assetKind(for: name, sessionID: sessionID) else {
                throw RecordingPackageError.unsupportedVisibleAsset(name)
            }
            guard assets[kind] == nil else {
                throw RecordingPackageError.duplicateAsset(kind)
            }
            assets[kind] = childURL
        }

        for kind in RecordingPackageAssetKind.allCases where kind.isCoreAsset {
            guard assets[kind] != nil else {
                throw RecordingPackageError.missingAsset(kind)
            }
        }

        if assets[.video] != nil, assets[.phoneMetadata] == nil {
            throw RecordingPackageError.videoMetadataRequired
        }

        let profile: RecordingPackageProfile =
            assets.keys.contains(where: { !$0.isCoreAsset }) ? .extended : .core
        if let expectedProfile, expectedProfile != profile {
            throw RecordingPackageError.profileMismatch(expected: expectedProfile, actual: profile)
        }

        self.packageURL = packageURL
        self.sessionID = sessionID
        self.profile = profile
        self.deviceMotionURL = assets[.deviceMotion]!
        self.rawAccelerometerURL = assets[.rawAccelerometer]!
        self.watchMetadataURL = assets[.watchMetadata]!
        self.audioURL = assets[.audio]
        self.videoURL = assets[.video]
        self.phoneMetadataURL = assets[.phoneMetadata]
    }

    public var allAssetURLs: [URL] {
        [deviceMotionURL, rawAccelerometerURL, watchMetadataURL, audioURL, videoURL, phoneMetadataURL]
            .compactMap { $0 }
    }
}
