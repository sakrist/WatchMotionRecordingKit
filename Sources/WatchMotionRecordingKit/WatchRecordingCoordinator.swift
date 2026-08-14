import Combine
import CoreMotion
import Foundation
import OSLog

/// Coordinates one complete Watch recording from start request to file transfer.
///
/// App code uses this type as the single entry point. The coordinator publishes
/// lightweight state for SwiftUI, while the detailed session and sensor work is
/// implemented in the `Session` and `Motion` extension files.
///
/// Threading rules:
/// - Sensor batches are processed in order on one serial `OperationQueue`.
/// - SwiftUI-facing values are changed on the main thread.
/// - Metadata reads and writes are protected by `metadataLock`.
///
/// See `docs/RECORDING_FLOW.md` for the complete ordered recording flow.
public final class WatchRecordingCoordinator: ObservableObject {
    // MARK: - Published State

    /// `true` after preparation succeeds and until the session stops or fails.
    @Published public internal(set) var isRecording = false

    /// `true` while permissions and capture resources are being prepared.
    @Published public internal(set) var isPreparing = false

    /// The local wall-clock time at which motion samples began being accepted.
    @Published public internal(set) var recordingStartedAt: Date?

    /// Number of accepted 200 Hz device-motion samples in the current session.
    /// The independent 800 Hz raw-acceleration count is stored in final metadata.
    @Published public internal(set) var sampleCount = 0

    /// Latest user-acceleration vector magnitude, measured in g.
    @Published public internal(set) var latestAccelMagnitude = 0.0

    /// Latest rotation-rate vector magnitude, measured in radians per second.
    @Published public internal(set) var latestGyroMagnitude = 0.0

    /// Decimated acceleration values for the optional live preview only.
    /// These are not the samples written to the binary recording.
    @Published public internal(set) var recentAccelMagnitudes: [Double] = []

    /// Decimated rotation values for the optional live preview only.
    @Published public internal(set) var recentGyroMagnitudes: [Double] = []

    /// `true` while the session is prepared and waiting for its planned start.
    @Published public internal(set) var isArmed = false

    /// Seconds remaining before the shared Watch/iPhone start time.
    @Published public internal(set) var countdownSecondsRemaining: Double?

    /// Short user-facing description of the current recording state.
    @Published public internal(set) var statusMessage = "Idle"

    /// Number of completed sessions that still have files awaiting transfer.
    @Published public internal(set) var pendingSyncSessionCount = 0

    /// `true` while WatchConnectivity has recording files queued for delivery.
    @Published public internal(set) var isSyncing = false

    // MARK: - Dependencies

    let configuration: WatchRecordingConfiguration
    let logger = Logger(subsystem: "com.sakrist.WatchMotionRecordingKit", category: "WatchRecorder")
#if os(watchOS)
    var batchedSensorManager: CMBatchedSensorManager?
#endif
    var transport: any WatchRecordingTransport

    // A single lane is intentional: both sensor streams mutate shared timestamp,
    // buffering, and writer state, so concurrent processing would corrupt order.
    let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "WatchRecordingCoordinator.MotionQueue"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    // App-owned metadata can be changed while motion capture is active.
    let metadataLock = NSLock()

    // MARK: - Recording State

    // One session owns two independent binary streams plus optional sidecar files.
    var deviceMotionWriter: WatchMotionBinaryFileWriter?
    var rawAccelerometerWriter: WatchMotionBinaryFileWriter?
    var currentDeviceMotionFileURL: URL?
    var currentRawAccelerometerFileURL: URL?
    var currentMetadataFileURL: URL?
    var currentAudioFileURL: URL?
    var currentSessionID: String?
    var currentWatchMetadata: WatchRecordingMetadata?
    // Set only after iPhone video preparation accepts this session. Start/stop
    // controls must use this session state rather than the broader
    // configuration so a motion-only fallback never sends a late command.
    var usesPhoneRecording = false
    let audioCapture = WatchAudioCapture()
    // Both streams share one uptime-to-Unix clock projection, but each has its
    // own start gate because their first accepted samples can differ.
    var timeProjector: UnixTimeProjector?
    var deviceMotionGate: ScheduledSampleGate?
    var rawAccelerometerGate: ScheduledSampleGate?
    // Records accumulate here between the approximately one-second disk writes.
    var pendingDeviceMotionRecords: [WatchDeviceMotionBinaryRecord] = []
    var pendingRawAccelerometerRecords: [WatchRawAccelerometerBinaryRecord] = []
    var earliestAcceptedSampleUnix: Double?
    var lastFileWriteBatchUnix = 0.0
    var lastFileSynchronizationUnix = 0.0
    var activeMotionSessionID: String?
    var actualDeviceMotionFrequency: UInt16 = WatchMotionBinaryStream.deviceMotion.nominalFrequencyHz
    var actualRawAccelerometerFrequency: UInt16 = WatchMotionBinaryStream.rawAccelerometer.nominalFrequencyHz
    @MainActor var recordingLifecycle = WatchRecordingLifecycle()
    @MainActor var startupTask: Task<Void, Never>?
    @MainActor var startupTaskSessionID: String?
    // Startup is complete only after callbacks confirm both required frequencies.
    var deviceMotionStartupConfirmed = false
    var rawAccelerometerStartupConfirmed = false
    var reportedDeviceMotionFrequency = 0
    var reportedRawAccelerometerFrequency = 0
    var motionStartupTimeoutTask: Task<Void, Never>?
    var acceptedDeviceMotionSampleCount = 0
    var liveTelemetry: WatchLiveTelemetryBuffer

    // MARK: - Lifecycle

    /// Creates a coordinator and activates its file-transfer transport.
    ///
    /// - Parameters:
    ///   - configuration: Session timing, optional features, and buffering policy.
    ///   - transport: Watch/iPhone communication. Tests may supply a fake transport.
    public init(
        configuration: WatchRecordingConfiguration = WatchRecordingConfiguration(),
        transport: any WatchRecordingTransport = WatchConnectivityRecordingTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.liveTelemetry = WatchLiveTelemetryBuffer(
            maximumPointCount: configuration.maxHistorySamples
        )
        self.transport.fileTransferCompletionHandler = { [weak self] _, error, remainingTransferCount in
            guard let self else { return }
            if error == nil {
                WatchPendingRecordingStore.trimStoredSessions(retainingLast: self.configuration.retainedSessionLimit)
            }
            self.refreshPendingSyncSessionCount(
                outstandingFileTransferCount: remainingTransferCount
            )
        }
        self.transport.pendingTransferRetryRequestHandler = { [weak self] in
            self?.retryPendingRecordingTransfers()
        }
        transport.activate()
        refreshPendingSyncSessionCount()
        retryPendingRecordingTransfers()
    }

    /// Whether this Watch can provide both required batched sensor streams.
    public static var isHighFrequencyRecordingSupported: Bool {
#if os(watchOS)
        CMBatchedSensorManager.isDeviceMotionSupported && CMBatchedSensorManager.isAccelerometerSupported
#else
        false
#endif
    }

    /// Instance form of `isHighFrequencyRecordingSupported` for view code.
    public var isHighFrequencyRecordingSupported: Bool {
        Self.isHighFrequencyRecordingSupported
    }

    deinit {
        stopMotionSources()
    }

    // MARK: - Recording

    /// Begins asynchronous preparation of one recording session.
    ///
    /// Repeated start requests are ignored while a session is starting or active.
    /// Detailed startup is in `WatchRecordingCoordinator+Session.swift`.
    @MainActor
    public func startRecording() {
        guard isHighFrequencyRecordingSupported else {
            logger.error("High-frequency recording is unavailable. deviceMotionSupported=\(Self.isHighFrequencyRecordingSupported, privacy: .public)")
            setStatus("Recording is not supported on this Watch.")
            return
        }

        let sessionID = Self.makeSessionID()
        guard recordingLifecycle.beginStartup(sessionID: sessionID) else { return }

        logger.info("Recording start requested")
        isPreparing = true
        startupTaskSessionID = sessionID
        startupTask = Task { @MainActor [weak self] in
            await self?.startRecordingSession(sessionID: sessionID)
        }
    }

    /// Stops capture, finalizes all files, and queues the complete asset set.
    ///
    /// Sensor sources are stopped and their serial queue is fully drained before
    /// file headers or metadata are finalized. This prevents late callbacks from
    /// writing into files that have already been transferred.
    @MainActor
    public func stopRecording() {
        guard let stopAction = recordingLifecycle.beginStop() else { return }

        if case .cancelStartup(let sessionID) = stopAction {
            cancelStartupTask(sessionID: sessionID)
            if currentSessionID == sessionID {
                if usesPhoneRecording {
                    transport.sendRecordingControl(action: .stop, sessionID: sessionID)
                }
                cleanupIncompleteSession()
            }
            isRecording = false
            isArmed = false
            countdownSecondsRemaining = nil
            recordingStartedAt = nil
            isPreparing = false
            statusMessage = "Stopped"
            return
        }

        guard case .finishRecording(let sessionID) = stopAction else { return }

        // Stop optional phone video immediately. Motion files still need to drain
        // and finalize, but that work must not keep the iPhone recording screen
        // open or extend the video past the user's stop action.
        if usesPhoneRecording {
            transport.sendRecordingControl(action: .stop, sessionID: sessionID)
            usesPhoneRecording = false
        }

        isArmed = false
        countdownSecondsRemaining = nil
        recordingStartedAt = nil

        do {
            // This also force-writes any records left in the one-second buffers.
            try stopMotionCaptureAndDrain()
            audioCapture.stop()
            guard currentSessionID == sessionID,
                  let deviceMotionWriter,
                  let rawAccelerometerWriter,
                  let currentDeviceMotionFileURL,
                  let currentRawAccelerometerFileURL,
                  let currentMetadataFileURL
            else {
                throw CocoaError(.fileWriteUnknown)
            }

            // Finalization rewrites each binary header with its true sample count
            // and calculates the integrity information stored in metadata.
            let deviceMotionSummary = try deviceMotionWriter.finalize(
                actualFrequencyHz: actualDeviceMotionFrequency
            )
            let rawAccelerometerSummary = try rawAccelerometerWriter.finalize(
                actualFrequencyHz: actualRawAccelerometerFrequency
            )
            guard deviceMotionSummary.sampleCount > 0,
                  rawAccelerometerSummary.sampleCount > 0 else {
                throw WatchMotionCaptureError.emptyStream
            }
            self.deviceMotionWriter = nil
            self.rawAccelerometerWriter = nil

            try withMetadataLock {
                guard var metadata = currentWatchMetadata else {
                    throw CocoaError(.fileWriteUnknown)
                }
                if let earliestAcceptedSampleUnix {
                    metadata = metadata.replacingActualWatchStartUnix(earliestAcceptedSampleUnix)
                }
                metadata = metadata.finalized(
                    deviceMotion: deviceMotionSummary,
                    rawAccelerometer: rawAccelerometerSummary
                )
                currentWatchMetadata = metadata
                try saveWatchMetadata(to: currentMetadataFileURL, metadata: metadata)
            }

            usesPhoneRecording = false
            let files = [currentDeviceMotionFileURL, currentRawAccelerometerFileURL, currentMetadataFileURL, currentAudioFileURL].compactMap { $0 }
            logger.info(
                "Stopping session \(sessionID, privacy: .public). deviceSamples=\(deviceMotionSummary.sampleCount), rawSamples=\(rawAccelerometerSummary.sampleCount), queueing=\(files.map(\.lastPathComponent).joined(separator: ","), privacy: .public)"
            )
            // Transfer is asynchronous. Local files remain available until
            // WatchConnectivity confirms them individually.
            transport.transferRecordingFiles(sessionID: sessionID, fileURLs: files)
            refreshPendingSyncSessionCount()
            _ = recordingLifecycle.finishStop(sessionID: sessionID)
            sampleCount = Int(deviceMotionSummary.sampleCount)
            isRecording = false
            recordingStartedAt = nil
            statusMessage = "Stopped (queued motion)"
        } catch {
            logger.error("Recording finish failed. session=\(self.currentSessionID ?? "none", privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            _ = recordingLifecycle.fail(sessionID: sessionID)
            cleanupIncompleteSession()
            isRecording = false
            isArmed = false
            countdownSecondsRemaining = nil
            recordingStartedAt = nil
            statusMessage = "Failed to finish: \(error.localizedDescription)"
        }
    }

    @MainActor
    func finishStartupTask(sessionID: String) {
        guard startupTaskSessionID == sessionID else { return }
        startupTask = nil
        startupTaskSessionID = nil
        isPreparing = false
    }

    @MainActor
    func cancelStartupTask(sessionID: String) {
        guard startupTaskSessionID == sessionID else { return }
        startupTask?.cancel()
        startupTask = nil
        startupTaskSessionID = nil
        isPreparing = false
    }

    // MARK: - Live Telemetry

    /// Enables or disables the decimated live graph feed.
    ///
    /// This changes only Watch UI work. Full-rate binary recording continues
    /// unchanged whether the graph is visible or hidden.
    public func setLiveGraphEnabled(_ isEnabled: Bool) {
        motionQueue.addOperation { [weak self] in
            guard let self, self.liveTelemetry.setGraphEnabled(isEnabled) else { return }
            self.logger.info("Live Watch graph enabled=\(isEnabled, privacy: .public)")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recentAccelMagnitudes.removeAll(keepingCapacity: true)
                self.recentGyroMagnitudes.removeAll(keepingCapacity: true)
            }
        }
    }

    // MARK: - Recording Metadata

    /// Returns an app-owned text payload stored in the current session metadata.
    public func applicationMetadataPayload(forKey key: String) -> String? {
        withMetadataLock { currentWatchMetadata?.applicationPayloads[key] }
    }

    /// Adds, replaces, or removes app-owned metadata while recording.
    ///
    /// Passing `nil` removes the value for `key`. The sidecar is rewritten
    /// atomically so a partial metadata write is not left on disk.
    public func setApplicationMetadataPayload(_ payload: String?, forKey key: String) throws {
        guard isRecording else { return }
        try withMetadataLock {
            guard let currentWatchMetadata else { return }
            var payloads = currentWatchMetadata.applicationPayloads
            payloads[key] = payload
            let metadata = currentWatchMetadata.replacingApplicationPayloads(payloads)
            self.currentWatchMetadata = metadata
            if let currentMetadataFileURL {
                try saveWatchMetadata(to: currentMetadataFileURL, metadata: metadata)
            }
        }
    }

    // MARK: - Pending Transfers

    /// Recounts locally retained sessions that still contain untransferred files.
    public func refreshPendingSyncSessionCount(outstandingFileTransferCount: Int? = nil) {
        let count = WatchPendingRecordingStore.pendingSessions().count
        let transferCount = outstandingFileTransferCount ?? transport.outstandingFileTransferCount
        let isSyncing = transferCount > 0
        if Thread.isMainThread {
            pendingSyncSessionCount = count
            self.isSyncing = isSyncing
        } else {
            DispatchQueue.main.async {
                self.pendingSyncSessionCount = count
                self.isSyncing = isSyncing
            }
        }
    }

    /// Requeues every file that has not yet received a successful transfer marker.
    public func retryPendingRecordingTransfers() {
        let pendingSessions = WatchPendingRecordingStore.pendingSessions()
        for session in pendingSessions {
            transport.transferRecordingFiles(sessionID: session.sessionID, fileURLs: session.fileURLs)
        }
        refreshPendingSyncSessionCount()
    }

    /// Cancels queued transfers, clears sync markers, then queues retained files again.
    ///
    /// This is a recovery operation; it does not delete any recording data.
    public func resetPendingRecordingTransferState() {
        transport.cancelOutstandingFileTransfers()
        WatchPendingRecordingStore.resetSyncMarkers()
        refreshPendingSyncSessionCount()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.retryPendingRecordingTransfers()
        }
    }

    /// Publishes status safely regardless of the caller's queue.
    func setStatus(_ message: String) {
        if Thread.isMainThread {
            statusMessage = message
        } else {
            DispatchQueue.main.async { self.statusMessage = message }
        }
    }
}

// Core Motion and WatchConnectivity callbacks cross concurrency domains that are
// not fully annotated by Apple. Safety depends on the serial motion queue, main-
// thread publishing, and metadata lock documented on the coordinator above.
extension WatchRecordingCoordinator: @unchecked Sendable {}
