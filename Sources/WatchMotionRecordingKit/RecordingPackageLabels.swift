import Foundation

/// The intentionally small, reviewer-authored labels document stored beside a
/// recording package. The recording remains usable when this optional document
/// is absent or invalid; consumers opt into validation when they need labels.
public struct RecordingPackageLabels: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1
    public static let supportedLabel = "strike"
    public static let sampleCount = 80

    public let formatVersion: Int
    public let sessionID: String
    public let labels: [Range]

    public init(sessionID: String, labels: [Range]) {
        self.formatVersion = Self.currentFormatVersion
        self.sessionID = sessionID
        self.labels = labels
    }

    public struct Range: Codable, Sendable, Equatable {
        public let label: String
        public let startIndex: Int
        public let endIndex: Int
        public let startTimestampUnixMicroseconds: Int64
        public let endTimestampUnixMicroseconds: Int64

        public init(
            label: String = RecordingPackageLabels.supportedLabel,
            startIndex: Int,
            endIndex: Int,
            startTimestampUnixMicroseconds: Int64,
            endTimestampUnixMicroseconds: Int64
        ) {
            self.label = label
            self.startIndex = startIndex
            self.endIndex = endIndex
            self.startTimestampUnixMicroseconds = startTimestampUnixMicroseconds
            self.endTimestampUnixMicroseconds = endTimestampUnixMicroseconds
        }
    }

    /// Validates the document against the canonical device-motion sequence.
    /// Keeping this separate from `RecordingPackageDescriptor` lets package
    /// shape validation succeed even when optional reviewer data is malformed.
    public func validate(
        expectedSessionID: String,
        deviceMotionRecords: [WatchDeviceMotionBinaryRecord]
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw RecordingPackageLabelsError.unsupportedFormatVersion(formatVersion)
        }

        guard canonicalSessionID(sessionID) == canonicalSessionID(expectedSessionID) else {
            throw RecordingPackageLabelsError.sessionMismatch(expected: expectedSessionID, actual: sessionID)
        }

        var previousEndIndex: Int?
        for range in labels {
            guard range.label == Self.supportedLabel else {
                throw RecordingPackageLabelsError.unsupportedLabel(range.label)
            }
            guard range.endIndex - range.startIndex + 1 == Self.sampleCount else {
                throw RecordingPackageLabelsError.invalidSampleCount(
                    expected: Self.sampleCount,
                    actual: range.endIndex - range.startIndex + 1
                )
            }
            guard range.startIndex >= 0, range.endIndex < deviceMotionRecords.count else {
                throw RecordingPackageLabelsError.indexOutOfBounds(
                    startIndex: range.startIndex,
                    endIndex: range.endIndex,
                    sampleCount: deviceMotionRecords.count
                )
            }
            if let previousEndIndex, range.startIndex <= previousEndIndex {
                throw RecordingPackageLabelsError.rangesNotStrictlyOrdered
            }

            let startTimestamp = deviceMotionRecords[range.startIndex].timestampUnixMicroseconds
            let endTimestamp = deviceMotionRecords[range.endIndex].timestampUnixMicroseconds
            guard startTimestamp == range.startTimestampUnixMicroseconds,
                  endTimestamp == range.endTimestampUnixMicroseconds else {
                throw RecordingPackageLabelsError.timestampMismatch
            }
            previousEndIndex = range.endIndex
        }
    }

    public static func load(
        from url: URL,
        expectedSessionID: String,
        deviceMotionRecords: [WatchDeviceMotionBinaryRecord]
    ) throws -> Self {
        let labels = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try labels.validate(expectedSessionID: expectedSessionID, deviceMotionRecords: deviceMotionRecords)
        return labels
    }

    private func canonicalSessionID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString.lowercased()
    }
}

public enum RecordingPackageLabelsError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormatVersion(Int)
    case sessionMismatch(expected: String, actual: String)
    case unsupportedLabel(String)
    case invalidSampleCount(expected: Int, actual: Int)
    case indexOutOfBounds(startIndex: Int, endIndex: Int, sampleCount: Int)
    case rangesNotStrictlyOrdered
    case timestampMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            "Unsupported recording labels format version: \(version)."
        case .sessionMismatch(let expected, let actual):
            "Recording labels are for \(actual), not \(expected)."
        case .unsupportedLabel(let label):
            "Unsupported recording label: \(label)."
        case .invalidSampleCount(let expected, let actual):
            "Recording label has \(actual) samples; expected \(expected)."
        case .indexOutOfBounds:
            "Recording label indexes are outside the device-motion stream."
        case .rangesNotStrictlyOrdered:
            "Recording labels must be chronological and non-overlapping."
        case .timestampMismatch:
            "Recording label timestamps do not match the device-motion stream."
        }
    }
}
