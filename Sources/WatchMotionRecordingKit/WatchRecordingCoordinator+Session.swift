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
    @MainActor
    func startRecordingSession(sessionID: String) async {
        defer { finishStartupTask(sessionID: sessionID) }
        guard shouldContinueStartup(sessionID: sessionID) else { return }

        // Discard references to the previous completed session without deleting
        // its retained files. New failures may then clean up only this session.
        deviceMotionWriter = nil
        rawAccelerometerWriter = nil
        currentDeviceMotionFileURL = nil
        currentRawAccelerometerFileURL = nil
        currentMetadataFileURL = nil
        currentAudioFileURL = nil
        currentWatchMetadata = nil
        currentSessionID = sessionID
        usesPhoneRecording = false
        let preparationStartedUptime = ProcessInfo.processInfo.systemUptime

        do {
            // Audio is an optional asset. A declined permission leaves it out of
            // this session instead of preventing the core motion recording.
            let shouldRecordAudio: Bool
            if configuration.recordsAudio {
                shouldRecordAudio = await audioCapture.requestPermission()
                guard shouldContinueStartup(sessionID: sessionID) else { return }
                if !shouldRecordAudio {
                    logger.warning("Watch microphone permission is unavailable; continuing without audio. session=\(sessionID, privacy: .public)")
                }
            } else {
                shouldRecordAudio = false
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
            let audioURL = shouldRecordAudio
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
            resetPublishedSamples()

            // A prepare request reserves the iPhone video session and returns the
            // shared start time. Motion-first clients may fall back immediately
            // when optional video cannot be prepared.
            let scheduledStart: ScheduledStartResponse
            if configuration.coordinatesWithPhoneRecording {
                let response = await transport.requestScheduledStart(
                    sessionID: sessionID,
                    leadTime: configuration.scheduledLeadTime
                )
                guard shouldContinueStartup(sessionID: sessionID) else {
                    if response?.accepted == true {
                        transport.sendRecordingControl(action: .stop, sessionID: sessionID)
                    }
                    return
                }
                if let response, response.accepted {
                    usesPhoneRecording = true
                    scheduledStart = response
                } else if configuration.allowsPhoneRecordingFallback {
                    logger.notice("iPhone video was unavailable; continuing with motion only. session=\(sessionID, privacy: .public)")
                    scheduledStart = Self.immediateScheduledStart()
                } else {
                    throw WatchMotionCaptureError.phoneSyncUnavailable
                }
            } else {
                scheduledStart = Self.immediateScheduledStart()
            }
            let plannedStartUnix = scheduledStart.plannedStartUnix
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
                do {
                    try audioCapture.start(
                        at: audioURL,
                        plannedStartUnix: plannedStartUnix,
                        preparedUnix: createdUnix
                    )
                } catch {
                    logger.error("Watch audio could not start; continuing without audio. session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    try? FileManager.default.removeItem(at: audioURL)
                    currentAudioFileURL = nil
                }
            }

            let preparationMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - preparationStartedUptime) * 1_000
            )
            logger.info("Starting motion capture. session=\(sessionID, privacy: .public) preparationMs=\(preparationMilliseconds, privacy: .public) phoneCoordination=\(self.usesPhoneRecording, privacy: .public) watchAudio=\(self.currentAudioFileURL != nil, privacy: .public)")
            let frequencies = try startMotionCapture(sessionID: sessionID)
            actualDeviceMotionFrequency = frequencies.deviceMotion
            actualRawAccelerometerFrequency = frequencies.rawAccelerometer
            guard shouldContinueStartup(sessionID: sessionID) else { return }
            // Publish recording only after both Core Motion sources are installed.
            isRecording = true

            // Core Motion starts before the deadline to prove both streams work.
            // Their start gates discard any samples captured during this countdown.
            let scheduledDelay = WatchRecordingStartTiming.scheduledDelay(
                coordinatesWithPhoneRecording: usesPhoneRecording,
                plannedStartUnix: plannedStartUnix,
                nowUnix: Date().timeIntervalSince1970
            )
            if scheduledDelay > 0 {
                isArmed = true
                statusMessage = "Armed, starting soon"
                startCountdown(to: plannedStartUnix)
                do {
                    try await Task.sleep(nanoseconds: UInt64(scheduledDelay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard shouldContinueStartup(sessionID: sessionID), isRecording else { return }
            guard recordingLifecycle.completeStartup(sessionID: sessionID) else { return }
            isArmed = false
            countdownSecondsRemaining = nil
            recordingStartedAt = Date()
            // This message starts the matching phone movie and marks that the
            // Watch reached the shared start and is safe to treat as active.
            if usesPhoneRecording {
                transport.sendRecordingControl(action: .start, sessionID: sessionID)
            }
            statusMessage = "Recording motion"
        } catch {
            guard recordingLifecycle.fail(sessionID: sessionID) else { return }
            logger.error("Recording start failed. session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if usesPhoneRecording {
                logger.info("Stopping prepared iPhone video session after Watch startup failure. session=\(sessionID, privacy: .public)")
                transport.sendRecordingControl(action: .stop, sessionID: sessionID)
            }
            // Startup is all-or-nothing. Never leave a partial session available
            // for transfer or analysis.
            cleanupIncompleteSession()
            isRecording = false
            isArmed = false
            countdownSecondsRemaining = nil
            recordingStartedAt = nil
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Session State and Files

    /// Clears values from the previous session before the new session is shown.
    @MainActor
    private func resetPublishedSamples() {
        sampleCount = 0
        latestAccelMagnitude = 0
        latestGyroMagnitude = 0
        recentAccelMagnitudes.removeAll(keepingCapacity: true)
        recentGyroMagnitudes.removeAll(keepingCapacity: true)
        isArmed = false
        countdownSecondsRemaining = nil
        recordingStartedAt = nil
    }

    /// Returns an immediate local start for sessions that do not use iPhone video.
    private static func immediateScheduledStart() -> ScheduledStartResponse {
        ScheduledStartResponse(
            plannedStartUnix: Date().timeIntervalSince1970,
            accepted: true
        )
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
    @MainActor
    private func startCountdown(to plannedStartUnix: Double) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isArmed {
                let remaining = max(0, plannedStartUnix - Date().timeIntervalSince1970)
                self.countdownSecondsRemaining = remaining
                if remaining <= 0.05 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if self.isArmed { self.countdownSecondsRemaining = 0 }
        }
    }

    @MainActor
    private func shouldContinueStartup(sessionID: String) -> Bool {
        !Task.isCancelled && recordingLifecycle.isStarting(sessionID: sessionID)
    }

    // MARK: - Cleanup

    /// Stops all resources and removes every file belonging to an incomplete session.
    ///
    /// This method is intentionally safe to call after partial startup: each stop,
    /// reset, and file deletion tolerates resources that were never created.
    @MainActor
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
        usesPhoneRecording = false
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
    static func makeSessionID() -> String {
        UUID().uuidString.lowercased()
    }
}
