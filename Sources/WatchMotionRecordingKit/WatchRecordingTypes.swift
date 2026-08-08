import CoreMotion
import Foundation

/// Policy values for one `WatchRecordingCoordinator` instance.
///
/// Sensor rates are intentionally not configurable: supported recordings always
/// request native 200 Hz device motion and 800 Hz raw acceleration.
public struct WatchRecordingConfiguration: Sendable, Equatable {
    /// Seconds reserved for phone video coordination and Watch preparation.
    public let scheduledLeadTime: TimeInterval

    /// Maximum decimated points retained for the optional live Watch graph.
    public let maxHistorySamples: Int

    /// Whether this recording should try to coordinate with iPhone video.
    public let coordinatesWithPhoneRecording: Bool

    /// Whether motion may start locally if optional iPhone video cannot prepare.
    ///
    /// Keep this `false` for clients that require a synchronized video asset.
    /// Debug and motion-first clients can opt in to a resilient motion-only start.
    public let allowsPhoneRecordingFallback: Bool

    /// Whether the Watch also creates a microphone recording for the session.
    public let recordsAudio: Bool

    /// Minimum interval between normal binary append operations.
    public let fileWriteBatchInterval: TimeInterval

    /// Minimum interval between filesystem synchronization requests.
    public let fileSynchronizationInterval: TimeInterval

    /// Number of completed local sessions retained after successful transfers.
    public let retainedSessionLimit: Int

    /// Creates recording policy with battery-conscious production defaults.
    public init(
        scheduledLeadTime: TimeInterval = 2.0,
        maxHistorySamples: Int = 75,
        coordinatesWithPhoneRecording: Bool = true,
        allowsPhoneRecordingFallback: Bool = false,
        recordsAudio: Bool = false,
        fileWriteBatchInterval: TimeInterval = 1,
        fileSynchronizationInterval: TimeInterval = 60,
        retainedSessionLimit: Int = 10
    ) {
        self.scheduledLeadTime = scheduledLeadTime
        self.maxHistorySamples = maxHistorySamples
        self.coordinatesWithPhoneRecording = coordinatesWithPhoneRecording
        self.allowsPhoneRecordingFallback = allowsPhoneRecordingFallback
        self.recordsAudio = recordsAudio
        self.fileWriteBatchInterval = fileWriteBatchInterval
        self.fileSynchronizationInterval = fileSynchronizationInterval
        self.retainedSessionLimit = retainedSessionLimit
    }
}

/// Calculates only the intentional wait used to align Watch capture with an
/// iPhone recording. Local-only sessions must never inherit that delay.
enum WatchRecordingStartTiming {
    static func scheduledDelay(
        coordinatesWithPhoneRecording: Bool,
        plannedStartUnix: Double,
        nowUnix: Double
    ) -> TimeInterval {
        guard coordinatesWithPhoneRecording else { return 0 }
        return max(0, plannedStartUnix - nowUnix)
    }
}

/// Failures that make a recording incomplete and therefore unsafe to transfer.
enum WatchMotionCaptureError: LocalizedError {
    case unsupported
    case motionAccessDenied
    case deviceMotionUnavailable
    case rawAccelerometerUnavailable
    case microphonePermissionDenied
    case phoneSyncUnavailable
    case emptyStream
    case unexpectedDeviceMotionFrequency(Int)
    case unexpectedRawAccelerometerFrequency(Int)
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Recording is not supported on this Watch."
        case .motionAccessDenied:
            return "Motion access is disabled for this Watch app"
        case .deviceMotionUnavailable:
            return "200 Hz device motion did not start"
        case .rawAccelerometerUnavailable:
            return "800 Hz raw acceleration did not start"
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case .phoneSyncUnavailable:
            return "iPhone video could not be prepared for this recording"
        case .emptyStream:
            return "Recording stopped before both motion streams produced samples"
        case .unexpectedDeviceMotionFrequency(let frequency):
            return "Unexpected device-motion frequency: \(frequency) Hz"
        case .unexpectedRawAccelerometerFrequency(let frequency):
            return "Unexpected raw-acceleration frequency: \(frequency) Hz"
        case .startupTimedOut:
            return "Motion streams did not start. Check motion access and try again."
        }
    }
}

/// Immutable handoff from Core Motion's callback context to the serial motion queue.
///
/// Core Motion sample objects are read-only after delivery but are not annotated
/// `Sendable` by the framework, so this narrow wrapper carries that guarantee.
struct SendableDeviceMotionBatch: @unchecked Sendable {
    let samples: [CMDeviceMotion]
    let callbackUnixTime: Double
    let callbackSystemUptime: TimeInterval
}

/// Immutable raw-acceleration handoff to the serial motion queue.
struct SendableAccelerometerBatch: @unchecked Sendable {
    let samples: [CMAccelerometerData]
    let callbackUnixTime: Double
    let callbackSystemUptime: TimeInterval
}
