import Foundation

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

public struct WatchSampleTimingController: Sendable, Equatable {
    public private(set) var projector: UnixTimeProjector
    public private(set) var gate: ScheduledSampleGate

    public init(
        startUnixTime: Double,
        projector: UnixTimeProjector = UnixTimeProjector()
    ) {
        self.projector = projector
        self.gate = ScheduledSampleGate(startUnixTime: startUnixTime)
    }

    public mutating func evaluate(
        motionTimestamp: TimeInterval,
        unixNow: Double
    ) -> SampleGateDecision {
        let sampleUnixTime = projector.project(
            motionTimestamp: motionTimestamp,
            unixNow: unixNow
        )
        return gate.evaluate(sampleUnixTime: sampleUnixTime)
    }

    public mutating func evaluate(
        motionTimestamp: TimeInterval,
        unixNow: Double,
        systemUptimeNow: TimeInterval
    ) -> SampleGateDecision {
        let sampleUnixTime = projector.project(
            motionTimestamp: motionTimestamp,
            unixNow: unixNow,
            systemUptimeNow: systemUptimeNow
        )
        return gate.evaluate(sampleUnixTime: sampleUnixTime)
    }
}
