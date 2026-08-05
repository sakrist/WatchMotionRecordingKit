import Foundation

/// One main-thread update for the Watch recording interface.
///
/// This is intentionally separate from recorded data. It contains only enough
/// information to update labels and the optional low-cost graph.
struct WatchLiveTelemetrySnapshot: Sendable, Equatable {
    let sampleCount: Int
    let latestAccelMagnitude: Double
    let latestGyroMagnitude: Double
    let accelPoints: [Double]
    let gyroPoints: [Double]
    let includesGraph: Bool
}

/// Reduces high-frequency sensor data to a Watch-friendly UI update rate.
///
/// Binary recording never reads from this buffer. Turning the graph off, changing
/// its history length, or dropping preview points cannot alter saved sensor data.
struct WatchLiveTelemetryBuffer {
    /// SwiftUI receives at most ten updates per second.
    private static let updateInterval: TimeInterval = 0.1

    /// At 200 Hz, keeping one in eight samples produces roughly 25 graph points/sec.
    private static let graphDecimationFactor = 8

    private let maximumPointCount: Int
    private(set) var isGraphEnabled = false
    private var accelMagnitudes: [Double] = []
    private var gyroMagnitudes: [Double] = []
    private var graphDecimationCounter = 0
    private var lastUpdateUnix = 0.0

    init(maximumPointCount: Int) {
        self.maximumPointCount = max(maximumPointCount, 1)
    }

    /// Changes graph collection and clears points from the previous graph state.
    /// - Returns: `true` only when the enabled state actually changed.
    mutating func setGraphEnabled(_ isEnabled: Bool) -> Bool {
        guard isGraphEnabled != isEnabled else { return false }

        isGraphEnabled = isEnabled
        reset()
        return true
    }

    /// Clears preview history and allows the next eligible snapshot immediately.
    mutating func reset() {
        accelMagnitudes.removeAll(keepingCapacity: true)
        gyroMagnitudes.removeAll(keepingCapacity: true)
        graphDecimationCounter = 0
        lastUpdateUnix = 0
    }

    /// Returns `true` for one of every eight device-motion samples when enabled.
    mutating func shouldAppendGraphPoint() -> Bool {
        guard isGraphEnabled else { return false }

        let shouldAppend = graphDecimationCounter == 0
        graphDecimationCounter = (graphDecimationCounter + 1) % Self.graphDecimationFactor
        return shouldAppend
    }

    /// Estimates storage for a decimated callback batch to avoid array reallocations.
    func graphCapacity(for sampleCount: Int) -> Int {
        (sampleCount / Self.graphDecimationFactor) + 1
    }

    /// Adds already-decimated points and retains only the configured history length.
    mutating func appendGraphPoints(
        accelMagnitudes newAccelMagnitudes: [Double],
        gyroMagnitudes newGyroMagnitudes: [Double]
    ) {
        guard isGraphEnabled else { return }

        accelMagnitudes.append(contentsOf: newAccelMagnitudes)
        gyroMagnitudes.append(contentsOf: newGyroMagnitudes)
        trimHistory()
    }

    /// Creates a UI snapshot only when the ten-updates-per-second interval has elapsed.
    mutating func snapshotIfDue(
        now: TimeInterval,
        sampleCount: Int,
        latestAccelMagnitude: Double,
        latestGyroMagnitude: Double
    ) -> WatchLiveTelemetrySnapshot? {
        guard now - lastUpdateUnix >= Self.updateInterval else { return nil }
        lastUpdateUnix = now

        return WatchLiveTelemetrySnapshot(
            sampleCount: sampleCount,
            latestAccelMagnitude: latestAccelMagnitude,
            latestGyroMagnitude: latestGyroMagnitude,
            accelPoints: isGraphEnabled ? accelMagnitudes : [],
            gyroPoints: isGraphEnabled ? gyroMagnitudes : [],
            includesGraph: isGraphEnabled
        )
    }

    /// Bounds memory and the amount of graph data copied to SwiftUI.
    private mutating func trimHistory() {
        if accelMagnitudes.count > maximumPointCount {
            accelMagnitudes.removeFirst(accelMagnitudes.count - maximumPointCount)
        }
        if gyroMagnitudes.count > maximumPointCount {
            gyroMagnitudes.removeFirst(gyroMagnitudes.count - maximumPointCount)
        }
    }
}
