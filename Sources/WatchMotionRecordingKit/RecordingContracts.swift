import Foundation

/// Live recording commands sent from the Watch to the iPhone.
public enum RecordingControlAction: String, Codable, Sendable, CaseIterable {
    /// Ask the phone to reserve a video session and return a shared start time.
    case prepare

    /// Mark that Watch motion capture has reached the shared start time.
    case start

    /// Finish the matching iPhone video recording.
    case stop
}

public enum WatchRecordingCommand {
    public static let commandKey = "watchRecordingCommand"
    public static let retryPendingTransfers = "retryPendingTransfers"
}

/// Latest Watch state shared with the iPhone through application context.
public struct WatchRecordingStateContext: Sendable, Equatable {
    public static let isRecordingKey = "isRecording"
    public static let isSyncingKey = "isSyncing"
    public static let pendingSyncSessionCountKey = "pendingSyncSessionCount"

    public let isRecording: Bool
    public let isSyncing: Bool
    public let pendingSyncSessionCount: Int

    public init(isRecording: Bool, isSyncing: Bool, pendingSyncSessionCount: Int) {
        self.isRecording = isRecording
        self.isSyncing = isSyncing
        self.pendingSyncSessionCount = max(pendingSyncSessionCount, 0)
    }

    public init?(dictionary: [String: Any]) {
        guard let isRecording = dictionary[Self.isRecordingKey] as? Bool else {
            return nil
        }

        self.init(
            isRecording: isRecording,
            isSyncing: dictionary[Self.isSyncingKey] as? Bool ?? false,
            pendingSyncSessionCount: dictionary[Self.pendingSyncSessionCountKey] as? Int ?? 0
        )
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            Self.isRecordingKey: isRecording,
            Self.isSyncingKey: isSyncing,
            Self.pendingSyncSessionCountKey: pendingSyncSessionCount,
        ]
    }
}

/// Dictionary-compatible WatchConnectivity payload for a recording command.
public struct RecordingControlMessage: Codable, Sendable, Equatable {
    public static let actionKey = "recordingControl"
    public static let sessionIDKey = "sessionID"
    public static let leadTimeKey = "leadTime"

    public let action: RecordingControlAction
    public let sessionID: String
    public let leadTime: TimeInterval?

    public init(
        action: RecordingControlAction,
        sessionID: String,
        leadTime: TimeInterval? = nil
    ) {
        self.action = action
        self.sessionID = sessionID
        self.leadTime = leadTime
    }

    public init?(dictionary: [String: Any]) {
        guard
            let rawAction = dictionary[Self.actionKey] as? String,
            let action = RecordingControlAction(rawValue: rawAction),
            let sessionID = dictionary[Self.sessionIDKey] as? String
        else {
            return nil
        }

        self.init(
            action: action,
            sessionID: sessionID,
            leadTime: dictionary[Self.leadTimeKey] as? TimeInterval
        )
    }

    public var dictionaryRepresentation: [String: Any] {
        var dictionary: [String: Any] = [
            Self.actionKey: action.rawValue,
            Self.sessionIDKey: sessionID,
        ]

        if let leadTime {
            dictionary[Self.leadTimeKey] = leadTime
        }

        return dictionary
    }
}

/// iPhone reply to `.prepare`, containing the time shared by all session assets.
public struct ScheduledStartResponse: Codable, Sendable, Equatable {
    public static let plannedStartUnixKey = "plannedStartUnix"
    public static let acceptedKey = "accepted"

    public let plannedStartUnix: Double
    public let accepted: Bool

    public init(plannedStartUnix: Double, accepted: Bool) {
        self.plannedStartUnix = plannedStartUnix
        self.accepted = accepted
    }

    public init?(dictionary: [String: Any]) {
        guard
            let plannedStartUnix = dictionary[Self.plannedStartUnixKey] as? Double,
            let accepted = dictionary[Self.acceptedKey] as? Bool
        else {
            return nil
        }

        self.init(plannedStartUnix: plannedStartUnix, accepted: accepted)
    }

    public var dictionaryRepresentation: [String: Any] {
        [
            Self.plannedStartUnixKey: plannedStartUnix,
            Self.acceptedKey: accepted,
        ]
    }
}

/// Timing sidecar created by the iPhone for its video asset.
public struct PhoneRecordingMetadata: Codable, Sendable, Equatable {
    public let sessionID: String
    public let plannedStartUnix: Double
    public let preRollStartUnix: Double
    public let actualVideoStartUnix: Double?
    public let syncFlashUnix: Double
    public let createdUnix: Double

    public init(
        sessionID: String,
        plannedStartUnix: Double,
        preRollStartUnix: Double,
        actualVideoStartUnix: Double?,
        syncFlashUnix: Double,
        createdUnix: Double
    ) {
        self.sessionID = sessionID
        self.plannedStartUnix = plannedStartUnix
        self.preRollStartUnix = preRollStartUnix
        self.actualVideoStartUnix = actualVideoStartUnix
        self.syncFlashUnix = syncFlashUnix
        self.createdUnix = createdUnix
    }
}

/// Watch sidecar that describes both finalized binary streams and app payloads.
public struct WatchRecordingMetadata: Codable, Sendable, Equatable {
    public let sessionID: String
    public let plannedStartUnix: Double
    public let actualWatchStartUnix: Double
    public let actualDeviceMotionFrequency: Int
    public let actualRawAccelerometerFrequency: Int
    public let attitudeReferenceFrame: String?
    public let createdUnix: Double
    public let deviceMotionFileName: String?
    public let deviceMotionByteCount: UInt64?
    public let deviceMotionSHA256: String?
    public let deviceMotionFormatVersion: UInt16?
    public let deviceMotionSampleCount: UInt64?
    public let deviceMotionSaturationCount: UInt64?
    public let rawAccelerometerFileName: String?
    public let rawAccelerometerByteCount: UInt64?
    public let rawAccelerometerSHA256: String?
    public let rawAccelerometerFormatVersion: UInt16?
    public let rawAccelerometerSampleCount: UInt64?
    public let rawAccelerometerSaturationCount: UInt64?
    public let applicationPayloads: [String: String]

    public init(
        sessionID: String,
        plannedStartUnix: Double,
        actualWatchStartUnix: Double,
        actualDeviceMotionFrequency: Int = 200,
        actualRawAccelerometerFrequency: Int = 800,
        attitudeReferenceFrame: String? = nil,
        createdUnix: Double,
        deviceMotionFileName: String? = nil,
        deviceMotionByteCount: UInt64? = nil,
        deviceMotionSHA256: String? = nil,
        deviceMotionFormatVersion: UInt16? = nil,
        deviceMotionSampleCount: UInt64? = nil,
        deviceMotionSaturationCount: UInt64? = nil,
        rawAccelerometerFileName: String? = nil,
        rawAccelerometerByteCount: UInt64? = nil,
        rawAccelerometerSHA256: String? = nil,
        rawAccelerometerFormatVersion: UInt16? = nil,
        rawAccelerometerSampleCount: UInt64? = nil,
        rawAccelerometerSaturationCount: UInt64? = nil,
        applicationPayloads: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.plannedStartUnix = plannedStartUnix
        self.actualWatchStartUnix = actualWatchStartUnix
        self.actualDeviceMotionFrequency = actualDeviceMotionFrequency
        self.actualRawAccelerometerFrequency = actualRawAccelerometerFrequency
        self.attitudeReferenceFrame = attitudeReferenceFrame
        self.createdUnix = createdUnix
        self.deviceMotionFileName = deviceMotionFileName
        self.deviceMotionByteCount = deviceMotionByteCount
        self.deviceMotionSHA256 = deviceMotionSHA256
        self.deviceMotionFormatVersion = deviceMotionFormatVersion
        self.deviceMotionSampleCount = deviceMotionSampleCount
        self.deviceMotionSaturationCount = deviceMotionSaturationCount
        self.rawAccelerometerFileName = rawAccelerometerFileName
        self.rawAccelerometerByteCount = rawAccelerometerByteCount
        self.rawAccelerometerSHA256 = rawAccelerometerSHA256
        self.rawAccelerometerFormatVersion = rawAccelerometerFormatVersion
        self.rawAccelerometerSampleCount = rawAccelerometerSampleCount
        self.rawAccelerometerSaturationCount = rawAccelerometerSaturationCount
        self.applicationPayloads = applicationPayloads
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case plannedStartUnix
        case actualWatchStartUnix
        case actualDeviceMotionFrequency
        case actualRawAccelerometerFrequency
        case attitudeReferenceFrame
        case createdUnix
        case deviceMotionFileName
        case deviceMotionByteCount
        case deviceMotionSHA256
        case deviceMotionFormatVersion
        case deviceMotionSampleCount
        case deviceMotionSaturationCount
        case rawAccelerometerFileName
        case rawAccelerometerByteCount
        case rawAccelerometerSHA256
        case rawAccelerometerFormatVersion
        case rawAccelerometerSampleCount
        case rawAccelerometerSaturationCount
        case applicationPayloads
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        plannedStartUnix = try container.decode(Double.self, forKey: .plannedStartUnix)
        actualWatchStartUnix = try container.decode(Double.self, forKey: .actualWatchStartUnix)
        actualDeviceMotionFrequency = try container.decodeIfPresent(Int.self, forKey: .actualDeviceMotionFrequency) ?? 200
        actualRawAccelerometerFrequency = try container.decodeIfPresent(Int.self, forKey: .actualRawAccelerometerFrequency) ?? 800
        attitudeReferenceFrame = try container.decodeIfPresent(String.self, forKey: .attitudeReferenceFrame)
        createdUnix = try container.decode(Double.self, forKey: .createdUnix)
        deviceMotionFileName = try container.decodeIfPresent(String.self, forKey: .deviceMotionFileName)
        deviceMotionByteCount = try container.decodeIfPresent(UInt64.self, forKey: .deviceMotionByteCount)
        deviceMotionSHA256 = try container.decodeIfPresent(String.self, forKey: .deviceMotionSHA256)
        deviceMotionFormatVersion = try container.decodeIfPresent(UInt16.self, forKey: .deviceMotionFormatVersion)
        deviceMotionSampleCount = try container.decodeIfPresent(UInt64.self, forKey: .deviceMotionSampleCount)
        deviceMotionSaturationCount = try container.decodeIfPresent(UInt64.self, forKey: .deviceMotionSaturationCount)
        rawAccelerometerFileName = try container.decodeIfPresent(String.self, forKey: .rawAccelerometerFileName)
        rawAccelerometerByteCount = try container.decodeIfPresent(UInt64.self, forKey: .rawAccelerometerByteCount)
        rawAccelerometerSHA256 = try container.decodeIfPresent(String.self, forKey: .rawAccelerometerSHA256)
        rawAccelerometerFormatVersion = try container.decodeIfPresent(UInt16.self, forKey: .rawAccelerometerFormatVersion)
        rawAccelerometerSampleCount = try container.decodeIfPresent(UInt64.self, forKey: .rawAccelerometerSampleCount)
        rawAccelerometerSaturationCount = try container.decodeIfPresent(UInt64.self, forKey: .rawAccelerometerSaturationCount)
        applicationPayloads = try container.decodeIfPresent([String: String].self, forKey: .applicationPayloads) ?? [:]
    }

    public func replacingApplicationPayloads(_ applicationPayloads: [String: String]) -> Self {
        replacing(applicationPayloads: applicationPayloads)
    }

    public func replacingActualWatchStartUnix(_ actualWatchStartUnix: Double) -> Self {
        replacing(actualWatchStartUnix: actualWatchStartUnix)
    }

    public func finalized(
        deviceMotion: WatchMotionBinaryFileSummary,
        rawAccelerometer: WatchMotionBinaryFileSummary
    ) -> Self {
        replacing(
            actualDeviceMotionFrequency: Int(deviceMotion.actualFrequencyHz),
            actualRawAccelerometerFrequency: Int(rawAccelerometer.actualFrequencyHz),
            deviceMotion: deviceMotion,
            rawAccelerometer: rawAccelerometer
        )
    }

    private func replacing(
        actualWatchStartUnix: Double? = nil,
        actualDeviceMotionFrequency: Int? = nil,
        actualRawAccelerometerFrequency: Int? = nil,
        deviceMotion: WatchMotionBinaryFileSummary? = nil,
        rawAccelerometer: WatchMotionBinaryFileSummary? = nil,
        applicationPayloads: [String: String]? = nil
    ) -> Self {
        Self(
            sessionID: sessionID,
            plannedStartUnix: plannedStartUnix,
            actualWatchStartUnix: actualWatchStartUnix ?? self.actualWatchStartUnix,
            actualDeviceMotionFrequency: actualDeviceMotionFrequency ?? self.actualDeviceMotionFrequency,
            actualRawAccelerometerFrequency: actualRawAccelerometerFrequency ?? self.actualRawAccelerometerFrequency,
            attitudeReferenceFrame: attitudeReferenceFrame,
            createdUnix: createdUnix,
            deviceMotionFileName: deviceMotion?.fileName ?? deviceMotionFileName,
            deviceMotionByteCount: deviceMotion?.byteCount ?? deviceMotionByteCount,
            deviceMotionSHA256: deviceMotion?.sha256 ?? deviceMotionSHA256,
            deviceMotionFormatVersion: deviceMotion?.formatVersion ?? deviceMotionFormatVersion,
            deviceMotionSampleCount: deviceMotion?.sampleCount ?? deviceMotionSampleCount,
            deviceMotionSaturationCount: deviceMotionSaturationCount,
            rawAccelerometerFileName: rawAccelerometer?.fileName ?? rawAccelerometerFileName,
            rawAccelerometerByteCount: rawAccelerometer?.byteCount ?? rawAccelerometerByteCount,
            rawAccelerometerSHA256: rawAccelerometer?.sha256 ?? rawAccelerometerSHA256,
            rawAccelerometerFormatVersion: rawAccelerometer?.formatVersion ?? rawAccelerometerFormatVersion,
            rawAccelerometerSampleCount: rawAccelerometer?.sampleCount ?? rawAccelerometerSampleCount,
            rawAccelerometerSaturationCount: rawAccelerometerSaturationCount,
            applicationPayloads: applicationPayloads ?? self.applicationPayloads
        )
    }
}
