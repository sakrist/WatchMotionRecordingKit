import Foundation

/// Converts Core Motion's monotonic uptime timestamps into Unix wall-clock time.
///
/// The first observation establishes an anchor. Later samples use only timestamp
/// differences, so a wall-clock adjustment during recording cannot create jumps.
public struct UnixTimeProjector: Sendable, Equatable {
    public private(set) var unixTimeAnchor: Double?
    public private(set) var motionTimestampAnchor: TimeInterval?

    public init(
        unixTimeAnchor: Double? = nil,
        motionTimestampAnchor: TimeInterval? = nil
    ) {
        self.unixTimeAnchor = unixTimeAnchor
        self.motionTimestampAnchor = motionTimestampAnchor
    }

    /// Projects a timestamp when the supplied Unix time describes that same sample.
    public mutating func project(
        motionTimestamp: TimeInterval,
        unixNow: Double
    ) -> Double {
        if let unixTimeAnchor, let motionTimestampAnchor {
            return unixTimeAnchor + (motionTimestamp - motionTimestampAnchor)
        }

        unixTimeAnchor = unixNow
        motionTimestampAnchor = motionTimestamp
        return unixNow
    }

    /// Projects a batched sample by anchoring callback Unix time to system uptime.
    ///
    /// This overload is used for delayed Core Motion batches: the sample's original
    /// uptime timestamp is preserved instead of assigning every sample callback time.
    public mutating func project(
        motionTimestamp: TimeInterval,
        unixNow: Double,
        systemUptimeNow: TimeInterval
    ) -> Double {
        if let unixTimeAnchor, let motionTimestampAnchor {
            return unixTimeAnchor + (motionTimestamp - motionTimestampAnchor)
        }

        unixTimeAnchor = unixNow
        motionTimestampAnchor = systemUptimeNow
        return unixNow + (motionTimestamp - systemUptimeNow)
    }
}

/// Result of comparing one projected sample against the planned session start.
public struct SampleGateDecision: Sendable, Equatable {
    public let sampleUnixTime: Double
    public let shouldKeepSample: Bool
    public let isFirstAcceptedSample: Bool

    public init(
        sampleUnixTime: Double,
        shouldKeepSample: Bool,
        isFirstAcceptedSample: Bool
    ) {
        self.sampleUnixTime = sampleUnixTime
        self.shouldKeepSample = shouldKeepSample
        self.isFirstAcceptedSample = isFirstAcceptedSample
    }
}

/// Drops pre-roll motion samples and remembers the first accepted sample time.
public struct ScheduledSampleGate: Sendable, Equatable {
    public let startUnixTime: Double
    public private(set) var firstAcceptedSampleUnixTime: Double?

    public init(
        startUnixTime: Double,
        firstAcceptedSampleUnixTime: Double? = nil
    ) {
        self.startUnixTime = startUnixTime
        self.firstAcceptedSampleUnixTime = firstAcceptedSampleUnixTime
    }

    /// Decides whether one projected sample belongs to the useful recording interval.
    public mutating func evaluate(sampleUnixTime: Double) -> SampleGateDecision {
        guard sampleUnixTime >= startUnixTime else {
            return SampleGateDecision(
                sampleUnixTime: sampleUnixTime,
                shouldKeepSample: false,
                isFirstAcceptedSample: false
            )
        }

        let isFirstAcceptedSample = firstAcceptedSampleUnixTime == nil
        if isFirstAcceptedSample {
            firstAcceptedSampleUnixTime = sampleUnixTime
        }

        return SampleGateDecision(
            sampleUnixTime: sampleUnixTime,
            shouldKeepSample: true,
            isFirstAcceptedSample: isFirstAcceptedSample
        )
    }
}
