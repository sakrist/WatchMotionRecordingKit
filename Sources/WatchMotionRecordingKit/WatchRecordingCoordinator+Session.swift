import Foundation
import OSLog

// This file owns session-level ordering. Keep cross-device preparation, local
// resource startup, and failure cleanup visible together: changing their order
// can produce video without motion, motion without metadata, or leaked files.
extension WatchRecordingCoordinator {
    // MARK: - Session Lifecycle

    /// Prepares every resource and moves one session into its recording state.
    ///
    /// The iPhone is prepared before motion capture starts. Once the phone returns
    /// a planned Unix time, Watch motion gates and optional audio use that same
    /// time so independently captured assets can be aligned during analysis.
    func startRecordingSession() async {
        let sessionID = Self.makeSessionID()
        let preparationStartedUptime = ProcessInfo.processInfo.systemUptime
        var phoneVideoPrepared = false

        do {
            // Resolve permission before creating files or starting work that would
            // need to be rolled back if the user declines.
            if configuration.recordsAudio {
                guard await audioCapture.requestPermission() else {
                    throw WatchMotionCaptureError.microphonePermissionDenied
                }
            }
            // Create all local destinations under one UUID. The common identity is
            // how the phone and Watch later group their independently created files.
            let deviceMotionURL = try createAssetURL(
                fileName: WatchRecordingAssetNaming.deviceMotionFileName(sessionID: sessionID)
            )
            let rawAccelerometerURL = try createAssetURL(
                fileName: WatchRecordingAssetNaming.rawAccelerometerFileName(sessionID: sessionID)
            )
            let metadataURL = try createAssetURL(
                fileName: WatchRecordingAssetNaming.metadataFileName(sessionID: sessionID)
            )
            let audioURL = configuration.recordsAudio
                ? try createAssetURL(fileName: WatchRecordingAssetNaming.audioFileName(sessionID: sessionID))
                : nil
            deviceMotionWriter = try WatchMotionBinaryFileWriter(
                stream: .deviceMotion,
                fileURL: deviceMotionURL,
                sessionID: sessionID
            )
            rawAccelerometerWriter = try WatchMotionBinaryFileWriter(
                stream: .rawAccelerometer,
                fileURL: rawAccelerometerURL,
                sessionID: sessionID
            )
            currentDeviceMotionFileURL = deviceMotionURL
            currentRawAccelerometerFileURL = rawAccelerometerURL
            currentMetadataFileURL = metadataURL
            currentAudioFileURL = audioURL
            currentSessionID = sessionID
            await MainActor.run {
                self.resetPublishedSamples()
                self.currentFileName = WatchRecordingAssetNaming.baseName(sessionID: sessionID)
            }

            // A prepare request starts iPhone video pre-roll and returns the shared
            // future start time. Failure is fatal when synchronized video is required.
            let scheduledStart: ScheduledStartResponse?
            if configuration.coordinatesWithPhoneRecording {
                guard let response = await transport.requestScheduledStart(
                    sessionID: sessionID,
                    leadTime: configuration.scheduledLeadTime
                ), response.accepted else {
                    throw WatchMotionCaptureError.phoneSyncUnavailable
                }
                phoneVideoPrepared = true
                scheduledStart = response
            } else {
                scheduledStart = ScheduledStartResponse(
                    plannedStartUnix: Date().timeIntervalSince1970,
                    accepted: true
                )
            }
            let plannedStartUnix = scheduledStart?.plannedStartUnix ?? Date().timeIntervalSince1970
            let createdUnix = Date().timeIntervalSince1970

            // Reset timing and buffering only after the shared start time is known.
            // Each stream gets its own gate because 200 Hz and 800 Hz callbacks are
            // independent even though they share the same clock projection.
            timeProjector = UnixTimeProjector()
            deviceMotionGate = ScheduledSampleGate(startUnixTime: plannedStartUnix)
            rawAccelerometerGate = ScheduledSampleGate(startUnixTime: plannedStartUnix)
            earliestAcceptedSampleUnix = nil
            pendingDeviceMotionRecords.removeAll(keepingCapacity: true)
            pendingRawAccelerometerRecords.removeAll(keepingCapacity: true)
            lastFileWriteBatchUnix = createdUnix
            lastFileSynchronizationUnix = createdUnix
            currentWatchMetadata = WatchRecordingMetadata(
                sessionID: sessionID,
                plannedStartUnix: plannedStartUnix,
                actualWatchStartUnix: plannedStartUnix,
                actualDeviceMotionFrequency: 200,
                actualRawAccelerometerFrequency: 800,
                createdUnix: createdUnix
            )
            try saveCurrentWatchMetadata()

            // AVAudioRecorder uses its own device clock, so schedule it rather than
            // sleeping and issuing a best-effort start at the deadline.
            if let audioURL {
                try audioCapture.start(
                    at: audioURL,
                    plannedStartUnix: plannedStartUnix,
                    preparedUnix: createdUnix
                )
            }

            // Motion callbacks may publish telemetry immediately. Mark the session
            // active first so those valid callbacks are not rejected as stale.
            await MainActor.run {
                self.isRecording = true
            }
            let preparationMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - preparationStartedUptime) * 1_000
            )
            logger.info("Starting motion capture. session=\(sessionID, privacy: .public) preparationMs=\(preparationMilliseconds, privacy: .public) phoneCoordination=\(self.configuration.coordinatesWithPhoneRecording, privacy: .public) watchAudio=\(self.configuration.recordsAudio, privacy: .public)")
            let frequencies = try startMotionCapture(sessionID: sessionID)
            actualDeviceMotionFrequency = frequencies.deviceMotion
            actualRawAccelerometerFrequency = frequencies.rawAccelerometer

            // Core Motion starts before the deadline to prove both streams work.
            // Their start gates discard any samples captured during this countdown.
            let scheduledDelay = WatchRecordingStartTiming.scheduledDelay(
                coordinatesWithPhoneRecording: configuration.coordinatesWithPhoneRecording,
                plannedStartUnix: plannedStartUnix,
                nowUnix: Date().timeIntervalSince1970
            )
            if scheduledDelay > 0 {
                await MainActor.run {
                    self.isArmed = true
                    self.statusMessage = "Armed, starting soon"
                }
                startCountdown(to: plannedStartUnix)
                try? await Task.sleep(nanoseconds: UInt64(scheduledDelay * 1_000_000_000))
            }
            guard await MainActor.run(body: { self.isRecording }), currentSessionID == sessionID else { return }
            await MainActor.run {
                self.isArmed = false
                self.countdownSecondsRemaining = nil
            }
            // The phone normally already records pre-roll. This message marks that
            // the Watch reached the shared start and is safe to treat as active.
            if configuration.coordinatesWithPhoneRecording {
                transport.sendRecordingControl(action: .start, sessionID: sessionID)
            }
            await MainActor.run {
                self.statusMessage = "Recording motion"
            }
        } catch {
            logger.error("Recording start failed. session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if phoneVideoPrepared && configuration.coordinatesWithPhoneRecording {
                logger.info("Stopping iPhone video pre-roll after Watch startup failure. session=\(sessionID, privacy: .public)")
                transport.sendRecordingControl(action: .stop, sessionID: sessionID)
            }
            // Startup is all-or-nothing. Never leave a partial session available
            // for transfer or analysis.
            cleanupIncompleteSession()
            await MainActor.run {
                self.isRecording = false
                self.isArmed = false
                self.countdownSecondsRemaining = nil
                self.statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Session State and Files

    /// Clears values from the previous session before the new session is shown.
    private func resetPublishedSamples() {
        sampleCount = 0
        latestAccelMagnitude = 0
        latestGyroMagnitude = 0
        recentAccelMagnitudes.removeAll(keepingCapacity: true)
        recentGyroMagnitudes.removeAll(keepingCapacity: true)
        isArmed = false
        countdownSecondsRemaining = nil
    }

    /// Ensures the retained-recordings directory exists and returns one file URL.
    private func createAssetURL(fileName: String) throws -> URL {
        let directory = WatchPendingRecordingStore.recordingsDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    /// Atomically replaces the metadata sidecar so readers never see half-written JSON.
    func saveWatchMetadata(to url: URL, metadata: WatchRecordingMetadata) throws {
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
    }

    /// Saves the current metadata snapshot while holding the shared metadata lock.
    private func saveCurrentWatchMetadata() throws {
        try withMetadataLock {
            guard let currentMetadataFileURL, let currentWatchMetadata else { return }
            try saveWatchMetadata(to: currentMetadataFileURL, metadata: currentWatchMetadata)
        }
    }

    /// Serializes metadata changes from app code and recording finalization.
    func withMetadataLock<T>(_ body: () throws -> T) rethrows -> T {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        return try body()
    }

    /// Publishes a lightweight countdown without blocking the main thread.
    private func startCountdown(to plannedStartUnix: Double) {
        Task { [weak self] in
            guard let self else { return }
            while await MainActor.run(body: { self.isArmed }) {
                let remaining = max(0, plannedStartUnix - Date().timeIntervalSince1970)
                await MainActor.run { self.countdownSecondsRemaining = remaining }
                if remaining <= 0.05 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await MainActor.run {
                if self.isArmed { self.countdownSecondsRemaining = 0 }
            }
        }
    }

    // MARK: - Cleanup

    /// Stops all resources and removes every file belonging to an incomplete session.
    ///
    /// This method is intentionally safe to call after partial startup: each stop,
    /// reset, and file deletion tolerates resources that were never created.
    func cleanupIncompleteSession() {
        motionStartupTimeoutTask?.cancel()
        motionStartupTimeoutTask = nil
        try? stopMotionCaptureAndDrain()
        audioCapture.stop()
        deviceMotionWriter = nil
        rawAccelerometerWriter = nil
        for url in [
            currentDeviceMotionFileURL,
            currentRawAccelerometerFileURL,
            currentMetadataFileURL,
            currentAudioFileURL,
        ].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        currentDeviceMotionFileURL = nil
        currentRawAccelerometerFileURL = nil
        currentMetadataFileURL = nil
        currentAudioFileURL = nil
        currentSessionID = nil
        currentWatchMetadata = nil
        timeProjector = nil
        deviceMotionGate = nil
        rawAccelerometerGate = nil
        pendingDeviceMotionRecords.removeAll(keepingCapacity: true)
        pendingRawAccelerometerRecords.removeAll(keepingCapacity: true)
        acceptedDeviceMotionSampleCount = 0
        liveTelemetry.reset()
        earliestAcceptedSampleUnix = nil
        lastFileWriteBatchUnix = 0
        deviceMotionStartupConfirmed = false
        rawAccelerometerStartupConfirmed = false
        reportedDeviceMotionFrequency = 0
        reportedRawAccelerometerFrequency = 0
    }

    /// Creates the identity shared by every Watch and iPhone asset in one session.
    private static func makeSessionID() -> String {
        UUID().uuidString.lowercased()
    }
}
