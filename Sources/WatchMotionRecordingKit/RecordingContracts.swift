import Foundation

public enum RecordingControlAction: String, Codable, Sendable, CaseIterable {
    case prepare
    case start
    case stop
}

public enum WatchRecordingCommand {
    public static let commandKey = "watchRecordingCommand"
    public static let retryPendingTransfers = "retryPendingTransfers"
}

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

public struct WatchRecordingMetadata: Codable, Sendable, Equatable {
    public let sessionID: String
    public let plannedStartUnix: Double
    public let actualWatchStartUnix: Double
    public let requestedDeviceMotionInterval: Double
    public let attitudeReferenceFrame: String?
    public let createdUnix: Double
    public let applicationPayloads: [String: String]

    public init(
        sessionID: String,
        plannedStartUnix: Double,
        actualWatchStartUnix: Double,
        requestedDeviceMotionInterval: Double,
        attitudeReferenceFrame: String? = nil,
        createdUnix: Double,
        applicationPayloads: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.plannedStartUnix = plannedStartUnix
        self.actualWatchStartUnix = actualWatchStartUnix
        self.requestedDeviceMotionInterval = requestedDeviceMotionInterval
        self.attitudeReferenceFrame = attitudeReferenceFrame
        self.createdUnix = createdUnix
        self.applicationPayloads = applicationPayloads
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case plannedStartUnix
        case actualWatchStartUnix
        case requestedDeviceMotionInterval
        case attitudeReferenceFrame
        case createdUnix
        case applicationPayloads
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        plannedStartUnix = try container.decode(Double.self, forKey: .plannedStartUnix)
        actualWatchStartUnix = try container.decode(Double.self, forKey: .actualWatchStartUnix)
        requestedDeviceMotionInterval = try container.decode(Double.self, forKey: .requestedDeviceMotionInterval)
        attitudeReferenceFrame = try container.decodeIfPresent(String.self, forKey: .attitudeReferenceFrame)
        createdUnix = try container.decode(Double.self, forKey: .createdUnix)
        applicationPayloads = try container.decodeIfPresent([String: String].self, forKey: .applicationPayloads) ?? [:]
    }
}
