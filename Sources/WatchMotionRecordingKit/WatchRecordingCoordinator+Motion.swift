import CoreMotion
import Foundation
import OSLog

// Both Core Motion streams enter this file and then share one serial queue. That
// queue is the ordering boundary for timestamp projection, start gating, binary
// buffering, writer access, startup validation, and capture failures.
extension WatchRecordingCoordinator {
    // MARK: - Capture Lifecycle

    /// Starts native 200 Hz device motion and 800 Hz raw acceleration together.
    ///
    /// Core Motion may initially report a frequency of zero, so startup succeeds
    /// provisionally and is confirmed from later callbacks. A three-second timeout
    /// fails the whole session if both expected rates are not confirmed.
    func startMotionCapture(sessionID: String) throws -> (deviceMotion: UInt16, rawAccelerometer: UInt16) {
#if os(watchOS)
        guard Self.isHighFrequencyRecordingSupported else {
            throw WatchMotionCaptureError.unsupported
        }

        let authorization = CMBatchedSensorManager.authorizationStatus
        guard authorization != .denied, authorization != .restricted else {
            logger.error("Batched motion access is unavailable. session=\(sessionID, privacy: .public) authorization=\(authorization.rawValue, privacy: .public)")
            throw WatchMotionCaptureError.motionAccessDenied
        }

        activeMotionSessionID = sessionID
        actualDeviceMotionFrequency = WatchMotionBinaryStream.deviceMotion.nominalFrequencyHz
        actualRawAccelerometerFrequency = WatchMotionBinaryStream.rawAccelerometer.nominalFrequencyHz
        deviceMotionStartupConfirmed = false
        rawAccelerometerStartupConfirmed = false
        reportedDeviceMotionFrequency = 0
        reportedRawAccelerometerFrequency = 0
        motionStartupTimeoutTask?.cancel()
        acceptedDeviceMotionSampleCount = 0
        liveTelemetry.reset()

        let manager = CMBatchedSensorManager()
        batchedSensorManager = manager
        logger.info("Starting batched motion. session=\(sessionID, privacy: .public) authorization=\(authorization.rawValue, privacy: .public)")

        // Core Motion controls these callback contexts. Each callback captures an
        // immutable batch and immediately places it on our serial processing queue.
        manager.startDeviceMotionUpdates { [weak self] motions, error in
            guard let self else { return }
            if let error {
                self.logger.error("Device-motion callback failed. session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.enqueueMotionFailure(error, sessionID: sessionID)
                return
            }
            guard let motions, !motions.isEmpty else { return }
            let reportedFrequency = manager.deviceMotionDataFrequency
            let batch = SendableDeviceMotionBatch(
                samples: motions,
                callbackUnixTime: Date().timeIntervalSince1970,
                callbackSystemUptime: ProcessInfo.processInfo.systemUptime
            )
            self.motionQueue.addOperation { [weak self] in
                self?.appendDeviceMotionBatch(
                    batch,
                    reportedFrequency: reportedFrequency,
                    sessionID: sessionID
                )
            }
        }
        manager.startAccelerometerUpdates { [weak self] samples, error in
            guard let self else { return }
            if let error {
                self.logger.error("Raw-accelerometer callback failed. session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.enqueueMotionFailure(error, sessionID: sessionID)
                return
            }
            guard let samples, !samples.isEmpty else { return }
            let reportedFrequency = manager.accelerometerDataFrequency
            let batch = SendableAccelerometerBatch(
                samples: samples,
                callbackUnixTime: Date().timeIntervalSince1970,
                callbackSystemUptime: ProcessInfo.processInfo.systemUptime
            )
            self.motionQueue.addOperation { [weak self] in
                self?.appendAccelerometerBatch(
                    batch,
                    reportedFrequency: reportedFrequency,
                    sessionID: sessionID
                )
            }
        }

        let deviceFrequency = manager.deviceMotionDataFrequency
        let rawFrequency = manager.accelerometerDataFrequency
        logger.info("Batched motion requested. session=\(sessionID, privacy: .public) deviceActive=\(manager.isDeviceMotionActive, privacy: .public) rawActive=\(manager.isAccelerometerActive, privacy: .public) initialFrequencies=\(deviceFrequency, privacy: .public)/\(rawFrequency, privacy: .public)Hz")
        scheduleMotionStartupTimeout(sessionID: sessionID)

        // Core Motion can report zero frequencies until callbacks begin. Confirm the
        // 200/800 Hz contract from callbacks instead of failing synchronously here.
        return (
            WatchMotionBinaryStream.deviceMotion.nominalFrequencyHz,
            WatchMotionBinaryStream.rawAccelerometer.nominalFrequencyHz
        )
#else
        throw WatchMotionCaptureError.unsupported
#endif
    }

    // MARK: - Batch Processing

    /// Converts one device-motion callback into ordered binary records and UI data.
    ///
    /// The session ID rejects late callbacks from an older recording. Full-rate
    /// records go to disk buffers; only the optional live graph is decimated.
    private func appendDeviceMotionBatch(
        _ batch: SendableDeviceMotionBatch,
        reportedFrequency: Int,
        sessionID: String
    ) {
        guard activeMotionSessionID == sessionID, deviceMotionWriter != nil else { return }
        guard confirmDeviceMotionStartup(
            reportedFrequency: reportedFrequency,
            sessionID: sessionID
        ) else { return }
        // Encode into one contiguous batch before touching the file writer. This is
        // substantially cheaper than issuing a file write for every 200 Hz sample.
        var records: [WatchDeviceMotionBinaryRecord] = []
        records.reserveCapacity(batch.samples.count)
        let shouldCollectLiveGraph = liveTelemetry.isGraphEnabled
        var graphAccelMagnitudes: [Double] = []
        var graphGyroMagnitudes: [Double] = []
        if shouldCollectLiveGraph {
            let graphCapacity = liveTelemetry.graphCapacity(for: batch.samples.count)
            graphAccelMagnitudes.reserveCapacity(graphCapacity)
            graphGyroMagnitudes.reserveCapacity(graphCapacity)
        }
        var lastAccelerationX = 0.0
        var lastAccelerationY = 0.0
        var lastAccelerationZ = 0.0
        var lastRotationX = 0.0
        var lastRotationY = 0.0
        var lastRotationZ = 0.0
        do {
            for motion in timestampOrderedSamples(batch.samples, timestamp: { $0.timestamp }) {
                guard let decision = timingDecision(
                    timestamp: motion.timestamp,
                    callbackUnixTime: batch.callbackUnixTime,
                    callbackSystemUptime: batch.callbackSystemUptime,
                    stream: .deviceMotion
                ), decision.shouldKeepSample else { continue }
                noteAcceptedSample(at: decision.sampleUnixTime)
                let acceleration = motion.userAcceleration
                let rotation = motion.rotationRate
                let gravity = motion.gravity
                let quaternion = motion.attitude.quaternion
                lastAccelerationX = acceleration.x
                lastAccelerationY = acceleration.y
                lastAccelerationZ = acceleration.z
                lastRotationX = rotation.x
                lastRotationY = rotation.y
                lastRotationZ = rotation.z
                records.append(
                    WatchDeviceMotionBinaryRecord(
                        timestampUnixMicroseconds: try WatchMotionTimestamp.unixMicroseconds(from: decision.sampleUnixTime),
                        userAccelerationX: acceleration.x,
                        userAccelerationY: acceleration.y,
                        userAccelerationZ: acceleration.z,
                        rotationRateX: rotation.x,
                        rotationRateY: rotation.y,
                        rotationRateZ: rotation.z,
                        gravityX: gravity.x,
                        gravityY: gravity.y,
                        gravityZ: gravity.z,
                        quaternionW: quaternion.w,
                        quaternionX: quaternion.x,
                        quaternionY: quaternion.y,
                        quaternionZ: quaternion.z
                    )
                )
                if shouldCollectLiveGraph, liveTelemetry.shouldAppendGraphPoint() {
                    graphAccelMagnitudes.append(
                        magnitude3(x: acceleration.x, y: acceleration.y, z: acceleration.z)
                    )
                    graphGyroMagnitudes.append(
                        magnitude3(x: rotation.x, y: rotation.y, z: rotation.z)
                    )
                }
            }
            // Pending records are flushed on the configured interval. No averaging
            // or downsampling occurs before they are appended to the binary file.
            pendingDeviceMotionRecords.append(contentsOf: records)
            try flushPendingSensorWritesIfNeeded()
            try synchronizeIfNeeded()
        } catch {
            failMotionCapture(error, sessionID: sessionID)
            return
        }
        guard !records.isEmpty else { return }

        acceptedDeviceMotionSampleCount += records.count
        if shouldCollectLiveGraph {
            liveTelemetry.appendGraphPoints(
                accelMagnitudes: graphAccelMagnitudes,
                gyroMagnitudes: graphGyroMagnitudes
            )
        }
        publishLiveTelemetryIfNeeded(
            sessionID: sessionID,
            sampleCount: acceptedDeviceMotionSampleCount,
            latestAccelMagnitude: magnitude3(
                x: lastAccelerationX,
                y: lastAccelerationY,
                z: lastAccelerationZ
            ),
            latestGyroMagnitude: magnitude3(
                x: lastRotationX,
                y: lastRotationY,
                z: lastRotationZ
            )
        )
    }

    /// Converts one independent 800 Hz raw-acceleration batch into binary records.
    ///
    /// Raw acceleration is deliberately not aligned by array index with the 200 Hz
    /// device-motion stream. Its own timestamps preserve the real sample timing.
    private func appendAccelerometerBatch(
        _ batch: SendableAccelerometerBatch,
        reportedFrequency: Int,
        sessionID: String
    ) {
        guard activeMotionSessionID == sessionID, rawAccelerometerWriter != nil else { return }
        guard confirmRawAccelerometerStartup(
            reportedFrequency: reportedFrequency,
            sessionID: sessionID
        ) else { return }
        var records: [WatchRawAccelerometerBinaryRecord] = []
        records.reserveCapacity(batch.samples.count)
        do {
            for sample in timestampOrderedSamples(batch.samples, timestamp: { $0.timestamp }) {
                guard let decision = timingDecision(
                    timestamp: sample.timestamp,
                    callbackUnixTime: batch.callbackUnixTime,
                    callbackSystemUptime: batch.callbackSystemUptime,
                    stream: .rawAccelerometer
                ), decision.shouldKeepSample else { continue }
                noteAcceptedSample(at: decision.sampleUnixTime)
                records.append(
                    WatchRawAccelerometerBinaryRecord(
                        timestampUnixMicroseconds: try WatchMotionTimestamp.unixMicroseconds(from: decision.sampleUnixTime),
                        rawAccelerationX: sample.acceleration.x,
                        rawAccelerationY: sample.acceleration.y,
                        rawAccelerationZ: sample.acceleration.z
                    )
                )
            }
            pendingRawAccelerometerRecords.append(contentsOf: records)
            try flushPendingSensorWritesIfNeeded()
            try synchronizeIfNeeded()
        } catch {
            failMotionCapture(error, sessionID: sessionID)
        }
    }

    // MARK: - Startup Validation

    /// Validates the device-motion rate once Core Motion begins reporting it.
    private func confirmDeviceMotionStartup(
        reportedFrequency: Int,
        sessionID: String
    ) -> Bool {
        guard activeMotionSessionID == sessionID else { return false }

        reportedDeviceMotionFrequency = reportedFrequency
        guard reportedFrequency == 0 || reportedFrequency == WatchMotionBinaryStream.deviceMotion.nominalFrequencyHz else {
            logger.error("Unexpected device-motion frequency. session=\(sessionID, privacy: .public) frequency=\(reportedFrequency, privacy: .public)Hz")
            failMotionCapture(
                WatchMotionCaptureError.unexpectedDeviceMotionFrequency(reportedFrequency),
                sessionID: sessionID
            )
            return false
        }

        // Zero is a temporary Core Motion state, not proof that capture failed.
        guard reportedFrequency > 0 else {
            logger.warning("Device-motion batch arrived before its frequency was reported. session=\(sessionID, privacy: .public)")
            return true
        }

        if !deviceMotionStartupConfirmed {
            deviceMotionStartupConfirmed = true
            actualDeviceMotionFrequency = UInt16(reportedFrequency)
            logger.info("Device-motion stream confirmed. session=\(sessionID, privacy: .public) frequency=\(reportedFrequency, privacy: .public)Hz")
            finishMotionStartupIfReady(sessionID: sessionID)
        }
        return true
    }

    /// Validates the raw-acceleration rate once Core Motion begins reporting it.
    private func confirmRawAccelerometerStartup(
        reportedFrequency: Int,
        sessionID: String
    ) -> Bool {
        guard activeMotionSessionID == sessionID else { return false }

        reportedRawAccelerometerFrequency = reportedFrequency
        guard reportedFrequency == 0 || reportedFrequency == WatchMotionBinaryStream.rawAccelerometer.nominalFrequencyHz else {
            logger.error("Unexpected raw-accelerometer frequency. session=\(sessionID, privacy: .public) frequency=\(reportedFrequency, privacy: .public)Hz")
            failMotionCapture(
                WatchMotionCaptureError.unexpectedRawAccelerometerFrequency(reportedFrequency),
                sessionID: sessionID
            )
            return false
        }

        guard reportedFrequency > 0 else {
            logger.warning("Raw-accelerometer batch arrived before its frequency was reported. session=\(sessionID, privacy: .public)")
            return true
        }

        if !rawAccelerometerStartupConfirmed {
            rawAccelerometerStartupConfirmed = true
            actualRawAccelerometerFrequency = UInt16(reportedFrequency)
            logger.info("Raw-accelerometer stream confirmed. session=\(sessionID, privacy: .public) frequency=\(reportedFrequency, privacy: .public)Hz")
            finishMotionStartupIfReady(sessionID: sessionID)
        }
        return true
    }

    /// Cancels the startup deadline only after both streams are confirmed.
    private func finishMotionStartupIfReady(sessionID: String) {
        guard deviceMotionStartupConfirmed, rawAccelerometerStartupConfirmed else { return }

        motionStartupTimeoutTask?.cancel()
        motionStartupTimeoutTask = nil
        logger.info("High-frequency motion startup complete. session=\(sessionID, privacy: .public) frequencies=\(self.actualDeviceMotionFrequency, privacy: .public)/\(self.actualRawAccelerometerFrequency, privacy: .public)Hz")
    }

    /// Prevents a session from appearing active forever when callbacks never arrive.
    private func scheduleMotionStartupTimeout(sessionID: String) {
        guard !deviceMotionStartupConfirmed || !rawAccelerometerStartupConfirmed else { return }

        motionStartupTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.motionQueue.addOperation { [weak self] in
                self?.failMotionStartupIfNeeded(sessionID: sessionID)
            }
        }
    }

    /// Rechecks session identity and confirmation state when the deadline fires.
    private func failMotionStartupIfNeeded(sessionID: String) {
        guard activeMotionSessionID == sessionID else { return }
        guard !deviceMotionStartupConfirmed || !rawAccelerometerStartupConfirmed else { return }

        logger.error("High-frequency motion startup timed out. session=\(sessionID, privacy: .public) deviceConfirmed=\(self.deviceMotionStartupConfirmed, privacy: .public) rawConfirmed=\(self.rawAccelerometerStartupConfirmed, privacy: .public) reportedFrequencies=\(self.reportedDeviceMotionFrequency, privacy: .public)/\(self.reportedRawAccelerometerFrequency, privacy: .public)Hz")
        failMotionCapture(WatchMotionCaptureError.startupTimedOut, sessionID: sessionID)
    }

    // MARK: - Timestamping

    /// Converts a Core Motion uptime timestamp to Unix time and applies its stream gate.
    ///
    /// The shared projector anchors monotonic sensor time to wall-clock time. Separate
    /// gates ensure each stream independently drops samples before the planned start.
    private func timingDecision(
        timestamp: TimeInterval,
        callbackUnixTime: Double,
        callbackSystemUptime: TimeInterval,
        stream: WatchMotionBinaryStream
    ) -> SampleGateDecision? {
        guard var projector = timeProjector else { return nil }
        let sampleUnixTime = projector.project(
            motionTimestamp: timestamp,
            unixNow: callbackUnixTime,
            systemUptimeNow: callbackSystemUptime
        )
        timeProjector = projector

        switch stream {
        case .deviceMotion:
            guard var gate = deviceMotionGate else { return nil }
            let decision = gate.evaluate(sampleUnixTime: sampleUnixTime)
            deviceMotionGate = gate
            return decision
        case .rawAccelerometer:
            guard var gate = rawAccelerometerGate else { return nil }
            let decision = gate.evaluate(sampleUnixTime: sampleUnixTime)
            rawAccelerometerGate = gate
            return decision
        }
    }

    /// Tracks the first real sample time written into final session metadata.
    private func noteAcceptedSample(at unixTime: Double) {
        earliestAcceptedSampleUnix = min(earliestAcceptedSampleUnix ?? unixTime, unixTime)
    }

    /// Returns samples in timestamp order without sorting already ordered batches.
    ///
    /// Core Motion normally sends ordered batches, so the fast path avoids an
    /// allocation. Sorting is a defensive fallback for an unexpected callback.
    private func timestampOrderedSamples<T>(
        _ samples: [T],
        timestamp: (T) -> TimeInterval
    ) -> [T] {
        guard samples.count > 1 else { return samples }

        var previousTimestamp = timestamp(samples[0])
        for sample in samples.dropFirst() {
            let currentTimestamp = timestamp(sample)
            guard currentTimestamp >= previousTimestamp else {
                return samples.sorted { timestamp($0) < timestamp($1) }
            }
            previousTimestamp = currentTimestamp
        }
        return samples
    }

    // MARK: - File Synchronization and Failures

    /// Periodically asks the operating system to synchronize written bytes to storage.
    ///
    /// This is separate from one-second batching: batching controls append frequency,
    /// while synchronization controls how often already-written bytes are forced out.
    private func synchronizeIfNeeded() throws {
        let now = Date().timeIntervalSince1970
        guard now - lastFileSynchronizationUnix >= configuration.fileSynchronizationInterval else { return }
        try deviceMotionWriter?.synchronize()
        try rawAccelerometerWriter?.synchronize()
        lastFileSynchronizationUnix = now
    }

    /// Serializes callback errors with any batches that were already queued.
    private func enqueueMotionFailure(_ error: Error, sessionID: String) {
        motionQueue.addOperation { [weak self] in
            self?.failMotionCapture(error, sessionID: sessionID)
        }
    }

    /// Ends only the matching active session and publishes a readable failure state.
    private func failMotionCapture(_ error: Error, sessionID: String) {
        guard activeMotionSessionID == sessionID else { return }
        logger.error("Motion capture failed. session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        activeMotionSessionID = nil
        motionStartupTimeoutTask?.cancel()
        motionStartupTimeoutTask = nil
        DispatchQueue.main.async {
            guard self.isRecording, self.currentSessionID == sessionID else { return }
            guard self.recordingLifecycle.fail(sessionID: sessionID) else { return }
            self.cancelStartupTask(sessionID: sessionID)
            if self.usesPhoneRecording {
                self.logger.info("Stopping iPhone video after motion capture failure. session=\(sessionID, privacy: .public)")
                self.transport.sendRecordingControl(action: .stop, sessionID: sessionID)
            }
            self.isRecording = false
            self.recordingStartedAt = nil
            self.cleanupIncompleteSession()
            self.setStatus("Motion error: \(error.localizedDescription)")
        }
    }

    // MARK: - Drain and Buffered Writes

    /// Stops new callbacks, waits for queued callbacks, then writes every remaining record.
    ///
    /// This order is required before binary headers and hashes can be finalized.
    func stopMotionCaptureAndDrain() throws {
        motionStartupTimeoutTask?.cancel()
        motionStartupTimeoutTask = nil
        stopMotionSources()
        motionQueue.waitUntilAllOperationsAreFinished()
        try flushPendingSensorWrites(force: true)
        activeMotionSessionID = nil
    }

    /// Performs a normal interval-based flush during active recording.
    private func flushPendingSensorWritesIfNeeded() throws {
        try flushPendingSensorWrites(force: false)
    }

    /// Appends both pending streams; `force` bypasses the timer during shutdown.
    private func flushPendingSensorWrites(force: Bool) throws {
        guard force || !pendingDeviceMotionRecords.isEmpty || !pendingRawAccelerometerRecords.isEmpty else {
            return
        }

        let now = Date().timeIntervalSince1970
        guard force || now - lastFileWriteBatchUnix >= configuration.fileWriteBatchInterval else { return }

        if !pendingDeviceMotionRecords.isEmpty {
            try deviceMotionWriter?.append(contentsOf: pendingDeviceMotionRecords)
            pendingDeviceMotionRecords.removeAll(keepingCapacity: true)
        }
        if !pendingRawAccelerometerRecords.isEmpty {
            try rawAccelerometerWriter?.append(contentsOf: pendingRawAccelerometerRecords)
            pendingRawAccelerometerRecords.removeAll(keepingCapacity: true)
        }
        lastFileWriteBatchUnix = now
    }

    // MARK: - Shutdown

    /// Stops Core Motion at the source so no new batches should be delivered.
    func stopMotionSources() {
#if os(watchOS)
        batchedSensorManager?.stopDeviceMotionUpdates()
        batchedSensorManager?.stopAccelerometerUpdates()
        batchedSensorManager = nil
#endif
    }

    // MARK: - Live Telemetry

    /// Publishes a throttled snapshot to SwiftUI on the main thread.
    ///
    /// Session checks prevent a delayed UI block from showing values belonging to
    /// an old or failed recording.
    private func publishLiveTelemetryIfNeeded(
        sessionID: String,
        sampleCount: Int,
        latestAccelMagnitude: Double,
        latestGyroMagnitude: Double
    ) {
        guard let snapshot = liveTelemetry.snapshotIfDue(
            now: Date().timeIntervalSince1970,
            sampleCount: sampleCount,
            latestAccelMagnitude: latestAccelMagnitude,
            latestGyroMagnitude: latestGyroMagnitude
        ) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording, self.currentSessionID == sessionID else { return }

            self.sampleCount = snapshot.sampleCount
            self.latestAccelMagnitude = snapshot.latestAccelMagnitude
            self.latestGyroMagnitude = snapshot.latestGyroMagnitude
            if snapshot.includesGraph {
                self.recentAccelMagnitudes = snapshot.accelPoints
                self.recentGyroMagnitudes = snapshot.gyroPoints
            } else if !self.recentAccelMagnitudes.isEmpty || !self.recentGyroMagnitudes.isEmpty {
                self.recentAccelMagnitudes.removeAll(keepingCapacity: true)
                self.recentGyroMagnitudes.removeAll(keepingCapacity: true)
            }
        }
    }

    private func magnitude3(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
    }
}
