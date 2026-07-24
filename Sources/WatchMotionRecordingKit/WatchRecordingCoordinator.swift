import Combine
import CoreMotion
import Foundation
import OSLog

public struct WatchRecordingConfiguration: Sendable, Equatable {
    public let scheduledLeadTime: TimeInterval
    public let maxHistorySamples: Int
    public let coordinatesWithPhoneRecording: Bool
    public let fileSynchronizationInterval: TimeInterval
    public let retainedSessionLimit: Int

    public init(
        scheduledLeadTime: TimeInterval = 2.0,
        maxHistorySamples: Int = 150,
        coordinatesWithPhoneRecording: Bool = true,
        fileSynchronizationInterval: TimeInterval = 60,
        retainedSessionLimit: Int = 10
    ) {
        self.scheduledLeadTime = scheduledLeadTime
        self.maxHistorySamples = maxHistorySamples
        self.coordinatesWithPhoneRecording = coordinatesWithPhoneRecording
        self.fileSynchronizationInterval = fileSynchronizationInterval
        self.retainedSessionLimit = retainedSessionLimit
    }
}

private enum WatchMotionCaptureError: LocalizedError {
    case unsupported
    case deviceMotionUnavailable
    case rawAccelerometerUnavailable
    case emptyStream
    case unexpectedFrequency(deviceMotion: Int, rawAccelerometer: Int)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Recording is not supported on this Watch."
        case .deviceMotionUnavailable:
            return "200 Hz device motion did not start"
        case .rawAccelerometerUnavailable:
            return "800 Hz raw acceleration did not start"
        case .emptyStream:
            return "Recording stopped before both motion streams produced samples"
        case .unexpectedFrequency(let deviceMotion, let rawAccelerometer):
            return "Unexpected motion frequencies: \(deviceMotion)/\(rawAccelerometer) Hz"
        }
    }
}

private struct SendableDeviceMotionBatch: @unchecked Sendable {
    let samples: [CMDeviceMotion]
    let callbackUnixTime: Double
    let callbackSystemUptime: TimeInterval
}

private struct SendableAccelerometerBatch: @unchecked Sendable {
    let samples: [CMAccelerometerData]
    let callbackUnixTime: Double
    let callbackSystemUptime: TimeInterval
}

public final class WatchRecordingCoordinator: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var sampleCount = 0
    @Published public private(set) var currentFileName: String?
    @Published public private(set) var latestAccelMagnitude = 0.0
    @Published public private(set) var latestGyroMagnitude = 0.0
    @Published public private(set) var recentAccelMagnitudes: [Double] = []
    @Published public private(set) var recentGyroMagnitudes: [Double] = []
    @Published public private(set) var isArmed = false
    @Published public private(set) var countdownSecondsRemaining: Double?
    @Published public private(set) var statusMessage = "Idle"
    @Published public private(set) var pendingSyncSessionCount = 0

    private let configuration: WatchRecordingConfiguration
    private let logger = Logger(subsystem: "com.sakrist.WatchMotionRecordingKit", category: "WatchRecorder")
#if os(watchOS)
    private var batchedSensorManager: CMBatchedSensorManager?
#endif
    private var transport: any WatchRecordingTransport
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "WatchRecordingCoordinator.MotionQueue"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let metadataLock = NSLock()

    private var deviceMotionWriter: WatchMotionBinaryFileWriter?
    private var rawAccelerometerWriter: WatchMotionBinaryFileWriter?
    private var currentDeviceMotionFileURL: URL?
    private var currentRawAccelerometerFileURL: URL?
    private var currentMetadataFileURL: URL?
    private var currentSessionID: String?
    private var currentWatchMetadata: WatchRecordingMetadata?
    private var timeProjector: UnixTimeProjector?
    private var deviceMotionGate: ScheduledSampleGate?
    private var rawAccelerometerGate: ScheduledSampleGate?
    private var earliestAcceptedSampleUnix: Double?
    private var lastFileSynchronizationUnix = 0.0
    private var activeMotionSessionID: String?
    private var actualDeviceMotionFrequency: UInt16 = WatchMotionBinaryStream.deviceMotion.nominalFrequencyHz
    private var actualRawAccelerometerFrequency: UInt16 = WatchMotionBinaryStream.rawAccelerometer.nominalFrequencyHz
    private var isStartingRecording = false

    public init(
        configuration: WatchRecordingConfiguration = WatchRecordingConfiguration(),
        transport: any WatchRecordingTransport = WatchConnectivityRecordingTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.transport.fileTransferCompletionHandler = { [weak self] _, error in
            guard let self else { return }
            if error == nil {
                WatchPendingRecordingStore.trimStoredSessions(retainingLast: self.configuration.retainedSessionLimit)
            }
            self.refreshPendingSyncSessionCount()
        }
        self.transport.pendingTransferRetryRequestHandler = { [weak self] in
            self?.retryPendingRecordingTransfers()
        }
        transport.activate()
        refreshPendingSyncSessionCount()
        retryPendingRecordingTransfers()
    }

    public static var isHighFrequencyRecordingSupported: Bool {
#if os(watchOS)
        CMBatchedSensorManager.isDeviceMotionSupported && CMBatchedSensorManager.isAccelerometerSupported
#else
        false
#endif
    }

    public var isHighFrequencyRecordingSupported: Bool {
        Self.isHighFrequencyRecordingSupported
    }

    deinit {
        stopMotionSources()
    }

    public func startRecording() {
        guard !isRecording, !isStartingRecording else { return }
        guard isHighFrequencyRecordingSupported else {
            setStatus("Recording is not supported on this Watch.")
            return
        }

        isStartingRecording = true
        Task { [weak self] in
            guard let self else { return }
            await self.startRecordingSession()
            self.isStartingRecording = false
        }
    }

    public func stopRecording() {
        guard isRecording else { return }

        stopMotionCaptureAndDrain()
        isArmed = false
        countdownSecondsRemaining = nil

        do {
            guard let sessionID = currentSessionID,
                  let deviceMotionWriter,
                  let rawAccelerometerWriter,
                  let currentDeviceMotionFileURL,
                  let currentRawAccelerometerFileURL,
                  let currentMetadataFileURL
            else {
                throw CocoaError(.fileWriteUnknown)
            }

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
            sampleCount = Int(deviceMotionSummary.sampleCount)

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

            isRecording = false
            if configuration.coordinatesWithPhoneRecording {
                transport.sendRecordingControl(action: .stop, sessionID: sessionID)
            }
            let files = [currentDeviceMotionFileURL, currentRawAccelerometerFileURL, currentMetadataFileURL]
            logger.info(
                "Stopping session \(sessionID, privacy: .public). deviceSamples=\(deviceMotionSummary.sampleCount), rawSamples=\(rawAccelerometerSummary.sampleCount), queueing=\(files.map(\.lastPathComponent).joined(separator: ","), privacy: .public)"
            )
            transport.transferRecordingFiles(sessionID: sessionID, fileURLs: files)
            refreshPendingSyncSessionCount()
            statusMessage = "Stopped (queued motion)"
        } catch {
            isRecording = false
            cleanupIncompleteSession()
            setStatus("Failed to finish: \(error.localizedDescription)")
        }
    }

    public func startLogging() {
        startRecording()
    }

    public func stopLogging() {
        stopRecording()
    }

    public func applicationMetadataPayload(forKey key: String) -> String? {
        withMetadataLock { currentWatchMetadata?.applicationPayloads[key] }
    }

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

    public func refreshPendingSyncSessionCount() {
        let count = WatchPendingRecordingStore.pendingSessions().count
        if Thread.isMainThread {
            pendingSyncSessionCount = count
        } else {
            DispatchQueue.main.async { self.pendingSyncSessionCount = count }
        }
    }

    public func retryPendingRecordingTransfers() {
        let pendingSessions = WatchPendingRecordingStore.pendingSessions()
        for session in pendingSessions {
            transport.transferRecordingFiles(sessionID: session.sessionID, fileURLs: session.fileURLs)
        }
        refreshPendingSyncSessionCount()
    }

    public func resetPendingRecordingTransferState() {
        transport.cancelOutstandingFileTransfers()
        WatchPendingRecordingStore.resetSyncMarkers()
        refreshPendingSyncSessionCount()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.retryPendingRecordingTransfers()
        }
    }

    private func startRecordingSession() async {
        do {
            let sessionID = Self.makeSessionID()
            let deviceMotionURL = try createAssetURL(
                fileName: WatchRecordingAssetNaming.deviceMotionFileName(sessionID: sessionID)
            )
            let rawAccelerometerURL = try createAssetURL(
                fileName: WatchRecordingAssetNaming.rawAccelerometerFileName(sessionID: sessionID)
            )
            let metadataURL = try createAssetURL(
                fileName: WatchRecordingAssetNaming.metadataFileName(sessionID: sessionID)
            )
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
            currentSessionID = sessionID
            resetPublishedSamples()
            currentFileName = WatchRecordingAssetNaming.baseName(sessionID: sessionID)

            let scheduledStart = if configuration.coordinatesWithPhoneRecording {
                await transport.requestScheduledStart(
                    sessionID: sessionID,
                    leadTime: configuration.scheduledLeadTime
                )
            } else {
                ScheduledStartResponse(
                    plannedStartUnix: Date().timeIntervalSince1970,
                    accepted: true
                )
            }
            let plannedStartUnix = scheduledStart?.plannedStartUnix ?? Date().timeIntervalSince1970
            let createdUnix = Date().timeIntervalSince1970
            timeProjector = UnixTimeProjector()
            deviceMotionGate = ScheduledSampleGate(startUnixTime: plannedStartUnix)
            rawAccelerometerGate = ScheduledSampleGate(startUnixTime: plannedStartUnix)
            earliestAcceptedSampleUnix = nil
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

            isRecording = true
            let frequencies = try startMotionCapture(sessionID: sessionID)
            actualDeviceMotionFrequency = frequencies.deviceMotion
            actualRawAccelerometerFrequency = frequencies.rawAccelerometer

            if plannedStartUnix > Date().timeIntervalSince1970 {
                isArmed = true
                setStatus("Armed, starting soon")
                startCountdown(to: plannedStartUnix)
                let delay = max(0, plannedStartUnix - Date().timeIntervalSince1970)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard isRecording, currentSessionID == sessionID else { return }
            isArmed = false
            countdownSecondsRemaining = nil
            if configuration.coordinatesWithPhoneRecording {
                transport.sendRecordingControl(action: .start, sessionID: sessionID)
            }
            statusMessage = "Recording motion"
        } catch {
            isRecording = false
            isArmed = false
            countdownSecondsRemaining = nil
            cleanupIncompleteSession()
            setStatus(error.localizedDescription)
        }
    }

    private func startMotionCapture(sessionID: String) throws -> (deviceMotion: UInt16, rawAccelerometer: UInt16) {
#if os(watchOS)
        guard Self.isHighFrequencyRecordingSupported else {
            throw WatchMotionCaptureError.unsupported
        }

        activeMotionSessionID = sessionID
        let manager = CMBatchedSensorManager()
        batchedSensorManager = manager
        manager.startDeviceMotionUpdates { [weak self] motions, error in
            guard let self else { return }
            if let error {
                self.enqueueMotionFailure(error, sessionID: sessionID)
                return
            }
            guard let motions, !motions.isEmpty else { return }
            let batch = SendableDeviceMotionBatch(
                samples: motions,
                callbackUnixTime: Date().timeIntervalSince1970,
                callbackSystemUptime: ProcessInfo.processInfo.systemUptime
            )
            self.motionQueue.addOperation { [weak self] in
                self?.appendDeviceMotionBatch(batch, sessionID: sessionID)
            }
        }
        manager.startAccelerometerUpdates { [weak self] samples, error in
            guard let self else { return }
            if let error {
                self.enqueueMotionFailure(error, sessionID: sessionID)
                return
            }
            guard let samples, !samples.isEmpty else { return }
            let batch = SendableAccelerometerBatch(
                samples: samples,
                callbackUnixTime: Date().timeIntervalSince1970,
                callbackSystemUptime: ProcessInfo.processInfo.systemUptime
            )
            self.motionQueue.addOperation { [weak self] in
                self?.appendAccelerometerBatch(batch, sessionID: sessionID)
            }
        }

        let deviceFrequency = manager.deviceMotionDataFrequency
        let rawFrequency = manager.accelerometerDataFrequency
        guard deviceFrequency > 0 else {
            stopMotionSources()
            throw WatchMotionCaptureError.deviceMotionUnavailable
        }
        guard rawFrequency > 0 else {
            stopMotionSources()
            throw WatchMotionCaptureError.rawAccelerometerUnavailable
        }
        guard deviceFrequency == 200, rawFrequency == 800 else {
            stopMotionSources()
            throw WatchMotionCaptureError.unexpectedFrequency(
                deviceMotion: deviceFrequency,
                rawAccelerometer: rawFrequency
            )
        }
        return (UInt16(deviceFrequency), UInt16(rawFrequency))
#else
        throw WatchMotionCaptureError.unsupported
#endif
    }

    private func appendDeviceMotionBatch(_ batch: SendableDeviceMotionBatch, sessionID: String) {
        guard activeMotionSessionID == sessionID, let writer = deviceMotionWriter else { return }
        var accelMagnitudes: [Double] = []
        var gyroMagnitudes: [Double] = []
        do {
            for motion in batch.samples.sorted(by: { $0.timestamp < $1.timestamp }) {
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
                try writer.append(
                    WatchDeviceMotionBinaryRecord(
                        timestampUnixMicroseconds: WatchMotionTimestamp.unixMicroseconds(from: decision.sampleUnixTime),
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
                accelMagnitudes.append(magnitude3(x: acceleration.x, y: acceleration.y, z: acceleration.z))
                gyroMagnitudes.append(magnitude3(x: rotation.x, y: rotation.y, z: rotation.z))
            }
            try synchronizeIfNeeded()
        } catch {
            failMotionCapture(error, sessionID: sessionID)
            return
        }
        guard !accelMagnitudes.isEmpty else { return }
        let count = Int(writer.sampleCount)
        DispatchQueue.main.async {
            guard self.isRecording, self.currentSessionID == sessionID else { return }
            self.sampleCount = count
            self.latestAccelMagnitude = accelMagnitudes.last ?? 0
            self.latestGyroMagnitude = gyroMagnitudes.last ?? 0
            self.recentAccelMagnitudes.append(contentsOf: accelMagnitudes)
            self.recentGyroMagnitudes.append(contentsOf: gyroMagnitudes)
            self.trimHistory()
        }
    }

    private func appendAccelerometerBatch(_ batch: SendableAccelerometerBatch, sessionID: String) {
        guard activeMotionSessionID == sessionID, let writer = rawAccelerometerWriter else { return }
        do {
            for sample in batch.samples.sorted(by: { $0.timestamp < $1.timestamp }) {
                guard let decision = timingDecision(
                    timestamp: sample.timestamp,
                    callbackUnixTime: batch.callbackUnixTime,
                    callbackSystemUptime: batch.callbackSystemUptime,
                    stream: .rawAccelerometer
                ), decision.shouldKeepSample else { continue }
                noteAcceptedSample(at: decision.sampleUnixTime)
                try writer.append(
                    WatchRawAccelerometerBinaryRecord(
                        timestampUnixMicroseconds: WatchMotionTimestamp.unixMicroseconds(from: decision.sampleUnixTime),
                        rawAccelerationX: sample.acceleration.x,
                        rawAccelerationY: sample.acceleration.y,
                        rawAccelerationZ: sample.acceleration.z
                    )
                )
            }
            try synchronizeIfNeeded()
        } catch {
            failMotionCapture(error, sessionID: sessionID)
        }
    }

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

    private func noteAcceptedSample(at unixTime: Double) {
        earliestAcceptedSampleUnix = min(earliestAcceptedSampleUnix ?? unixTime, unixTime)
    }

    private func synchronizeIfNeeded() throws {
        let now = Date().timeIntervalSince1970
        guard now - lastFileSynchronizationUnix >= configuration.fileSynchronizationInterval else { return }
        try deviceMotionWriter?.synchronize()
        try rawAccelerometerWriter?.synchronize()
        lastFileSynchronizationUnix = now
    }

    private func enqueueMotionFailure(_ error: Error, sessionID: String) {
        motionQueue.addOperation { [weak self] in
            self?.failMotionCapture(error, sessionID: sessionID)
        }
    }

    private func failMotionCapture(_ error: Error, sessionID: String) {
        guard activeMotionSessionID == sessionID else { return }
        activeMotionSessionID = nil
        DispatchQueue.main.async {
            guard self.isRecording, self.currentSessionID == sessionID else { return }
            if self.configuration.coordinatesWithPhoneRecording {
                self.transport.sendRecordingControl(action: .stop, sessionID: sessionID)
            }
            self.isRecording = false
            self.cleanupIncompleteSession()
            self.setStatus("Motion error: \(error.localizedDescription)")
        }
    }

    private func stopMotionCaptureAndDrain() {
        stopMotionSources()
        motionQueue.waitUntilAllOperationsAreFinished()
        activeMotionSessionID = nil
    }

    private func stopMotionSources() {
#if os(watchOS)
        batchedSensorManager?.stopDeviceMotionUpdates()
        batchedSensorManager?.stopAccelerometerUpdates()
        batchedSensorManager = nil
#endif
    }

    private func resetPublishedSamples() {
        sampleCount = 0
        latestAccelMagnitude = 0
        latestGyroMagnitude = 0
        recentAccelMagnitudes.removeAll(keepingCapacity: true)
        recentGyroMagnitudes.removeAll(keepingCapacity: true)
        isArmed = false
        countdownSecondsRemaining = nil
    }

    private func trimHistory() {
        if recentAccelMagnitudes.count > configuration.maxHistorySamples {
            recentAccelMagnitudes.removeFirst(recentAccelMagnitudes.count - configuration.maxHistorySamples)
        }
        if recentGyroMagnitudes.count > configuration.maxHistorySamples {
            recentGyroMagnitudes.removeFirst(recentGyroMagnitudes.count - configuration.maxHistorySamples)
        }
    }

    private func magnitude3(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
    }

    private func createAssetURL(fileName: String) throws -> URL {
        let directory = WatchPendingRecordingStore.recordingsDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    private func saveWatchMetadata(to url: URL, metadata: WatchRecordingMetadata) throws {
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
    }

    private func saveCurrentWatchMetadata() throws {
        try withMetadataLock {
            guard let currentMetadataFileURL, let currentWatchMetadata else { return }
            try saveWatchMetadata(to: currentMetadataFileURL, metadata: currentWatchMetadata)
        }
    }

    private func withMetadataLock<T>(_ body: () throws -> T) rethrows -> T {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        return try body()
    }

    private func startCountdown(to plannedStartUnix: Double) {
        Task { [weak self] in
            guard let self else { return }
            while self.isArmed {
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

    private func cleanupIncompleteSession() {
        stopMotionCaptureAndDrain()
        deviceMotionWriter = nil
        rawAccelerometerWriter = nil
        for url in [
            currentDeviceMotionFileURL,
            currentRawAccelerometerFileURL,
            currentMetadataFileURL,
        ].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        isRecording = false
        isArmed = false
        countdownSecondsRemaining = nil
        currentDeviceMotionFileURL = nil
        currentRawAccelerometerFileURL = nil
        currentMetadataFileURL = nil
        currentSessionID = nil
        currentWatchMetadata = nil
        timeProjector = nil
        deviceMotionGate = nil
        rawAccelerometerGate = nil
        earliestAcceptedSampleUnix = nil
    }

    private static func makeSessionID() -> String {
        UUID().uuidString.lowercased()
    }

    private func setStatus(_ message: String) {
        if Thread.isMainThread {
            statusMessage = message
        } else {
            DispatchQueue.main.async { self.statusMessage = message }
        }
    }
}

extension WatchRecordingCoordinator: @unchecked Sendable {}
