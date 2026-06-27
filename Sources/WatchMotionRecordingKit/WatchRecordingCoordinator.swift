import Foundation
import CoreMotion
import Combine
import AVFoundation
import OSLog

public enum WatchRecordingCSVField: String, CaseIterable, Sendable, Equatable {
    case timestamp
    case ax
    case ay
    case az
    case gx
    case gy
    case gz
    case grx
    case gry
    case grz
    case qw
    case qx
    case qy
    case qz
    case heading
    case mX
    case mY
    case mZ

    public static let defaultFields: [WatchRecordingCSVField] = [
        .timestamp,
        .ax,
        .ay,
        .az,
        .gx,
        .gy,
        .gz,
        .grx,
        .gry,
        .grz,
        .qw,
        .qx,
        .qy,
        .qz,
        .heading,
        .mX,
        .mY,
        .mZ,
    ]
}

public struct WatchRecordingConfiguration: Sendable, Equatable {
    public let requestedDeviceMotionInterval: TimeInterval
    public let scheduledLeadTime: TimeInterval
    public let maxHistorySamples: Int
    public let recordsAudio: Bool
    public let coordinatesWithPhoneRecording: Bool
    public let fileSynchronizationInterval: TimeInterval
    public let csvFields: [WatchRecordingCSVField]

    public init(
        requestedDeviceMotionInterval: TimeInterval = 1.0 / 200.0,
        scheduledLeadTime: TimeInterval = 2.0,
        maxHistorySamples: Int = 150,
        recordsAudio: Bool = true,
        coordinatesWithPhoneRecording: Bool = true,
        fileSynchronizationInterval: TimeInterval = 60,
        csvFields: [WatchRecordingCSVField] = WatchRecordingCSVField.defaultFields
    ) {
        self.requestedDeviceMotionInterval = requestedDeviceMotionInterval
        self.scheduledLeadTime = scheduledLeadTime
        self.maxHistorySamples = maxHistorySamples
        self.recordsAudio = recordsAudio
        self.coordinatesWithPhoneRecording = coordinatesWithPhoneRecording
        self.fileSynchronizationInterval = fileSynchronizationInterval
        self.csvFields = csvFields
    }
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
    private let motionManager: CMMotionManager
    private var transport: any WatchRecordingTransport
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "WatchRecordingCoordinator.MotionQueue"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let fileQueue = DispatchQueue(label: "WatchRecordingCoordinator.FileQueue")
    private var fileHandle: FileHandle?
    private var currentCSVFileURL: URL?
    private var currentAudioFileURL: URL?
    private var currentMetadataFileURL: URL?
    private var currentSessionID: String?
    private var currentAttitudeReferenceFrameName: String?
    private var audioRecorder: AVAudioRecorder?
    private var currentWatchMetadata: WatchRecordingMetadata?
    private var sampleTimingController: WatchSampleTimingController?
    private var lastFileSynchronizationUnix = 0.0

    public init(
        configuration: WatchRecordingConfiguration = WatchRecordingConfiguration(),
        motionManager: CMMotionManager = CMMotionManager(),
        transport: any WatchRecordingTransport = WatchConnectivityRecordingTransport()
    ) {
        self.configuration = configuration
        self.motionManager = motionManager
        self.transport = transport
        self.transport.fileTransferCompletionHandler = { [weak self] _, _ in
            self?.refreshPendingSyncSessionCount()
        }
        self.transport.pendingTransferRetryRequestHandler = { [weak self] in
            self?.retryPendingRecordingTransfers()
        }
        transport.activate()
        logger.info("Recorder initialized. audio=\(configuration.recordsAudio), phoneCoordination=\(configuration.coordinatesWithPhoneRecording), syncInterval=\(configuration.fileSynchronizationInterval)")
        refreshPendingSyncSessionCount()
        retryPendingRecordingTransfers()
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        audioRecorder?.stop()
        try? fileHandle?.close()
    }

    public func startRecording() {
        guard !isRecording else { return }

        Task { [weak self] in
            await self?.startRecordingSession()
        }
    }

    public func stopRecording() {
        guard isRecording else { return }

        motionManager.stopDeviceMotionUpdates()
        audioRecorder?.stop()
        audioRecorder = nil
        isArmed = false
        countdownSecondsRemaining = nil
        if configuration.recordsAudio {
            try? AVAudioSession.sharedInstance().setActive(false)
        }

        let handle = fileHandle
        fileHandle = nil

        fileQueue.sync {
            try? handle?.synchronize()
            try? handle?.close()
        }

        isRecording = false

        if let sessionID = currentSessionID {
            if configuration.coordinatesWithPhoneRecording {
                transport.sendRecordingControl(action: .stop, sessionID: sessionID)
            }
            let files = [currentCSVFileURL, currentAudioFileURL, currentMetadataFileURL].compactMap { $0 }
            logger.info("Stopping session \(sessionID, privacy: .public). samples=\(self.sampleCount), queueing files=\(files.map(\.lastPathComponent).joined(separator: ","), privacy: .public)")
            transport.transferRecordingFiles(sessionID: sessionID, fileURLs: files)
            refreshPendingSyncSessionCount()
            statusMessage = configuration.recordsAudio ? "Stopped (queued motion + audio)" : "Stopped (queued motion)"
        } else {
            statusMessage = "Stopped"
        }
    }

    public func startLogging() {
        startRecording()
    }

    public func stopLogging() {
        stopRecording()
    }

    public func applicationMetadataPayload(forKey key: String) -> String? {
        currentWatchMetadata?.applicationPayloads[key]
    }

    public func setApplicationMetadataPayload(_ payload: String?, forKey key: String) throws {
        guard isRecording, let currentWatchMetadata else { return }

        var applicationPayloads = currentWatchMetadata.applicationPayloads
        applicationPayloads[key] = payload

        self.currentWatchMetadata = WatchRecordingMetadata(
            sessionID: currentWatchMetadata.sessionID,
            plannedStartUnix: currentWatchMetadata.plannedStartUnix,
            actualWatchStartUnix: currentWatchMetadata.actualWatchStartUnix,
            requestedDeviceMotionInterval: currentWatchMetadata.requestedDeviceMotionInterval,
            attitudeReferenceFrame: currentWatchMetadata.attitudeReferenceFrame,
            createdUnix: currentWatchMetadata.createdUnix,
            applicationPayloads: applicationPayloads
        )

        try saveCurrentWatchMetadata()
    }

    public func refreshPendingSyncSessionCount() {
        let count = WatchPendingRecordingStore.pendingSessions().count
        logger.info("Pending watch recording sessions: \(count)")

        if Thread.isMainThread {
            pendingSyncSessionCount = count
        } else {
            DispatchQueue.main.async {
                self.pendingSyncSessionCount = count
            }
        }
    }

    public func retryPendingRecordingTransfers() {
        let pendingSessions = WatchPendingRecordingStore.pendingSessions()
        logger.info("Retrying pending transfers. sessions=\(pendingSessions.count)")
        for session in pendingSessions {
            transport.transferRecordingFiles(sessionID: session.sessionID, fileURLs: session.fileURLs)
        }
        refreshPendingSyncSessionCount()
    }

    public func resetPendingRecordingTransferState() {
        logger.info("Resetting pending recording transfer state")
        transport.cancelOutstandingFileTransfers()
        WatchPendingRecordingStore.resetSyncMarkers()
        refreshPendingSyncSessionCount()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.retryPendingRecordingTransfers()
        }
    }

    private func startRecordingSession() async {
        guard motionManager.isDeviceMotionAvailable else {
            setStatus("Device motion unavailable")
            return
        }

        if configuration.recordsAudio {
            let hasAudioPermission = await requestAudioPermission()
            guard hasAudioPermission else {
                setStatus("Microphone permission denied")
                return
            }
        }

        do {
            let sessionID = Self.makeSessionID()
            let attitudeReferenceFrame = Self.preferredAttitudeReferenceFrame()
            let attitudeReferenceFrameName = Self.name(for: attitudeReferenceFrame)
            logger.info("Starting recording session \(sessionID, privacy: .public)")
            let csvFileURL = try createRecordingFileURL(sessionID: sessionID, fileExtension: "csv")
            let metadataFileURL = try createMetadataFileURL(sessionID: sessionID)
            let handle = try prepareLogFile(at: csvFileURL)
            let audioFileURL = configuration.recordsAudio ? try createRecordingFileURL(sessionID: sessionID, fileExtension: "m4a") : nil
            let recorder = try audioFileURL.map { try prepareAudioRecorder(at: $0) }

            fileHandle = handle
            currentCSVFileURL = csvFileURL
            currentAudioFileURL = audioFileURL
            currentMetadataFileURL = metadataFileURL
            currentSessionID = sessionID
            currentAttitudeReferenceFrameName = attitudeReferenceFrameName
            audioRecorder = recorder

            sampleCount = 0
            latestAccelMagnitude = 0
            latestGyroMagnitude = 0
            lastFileSynchronizationUnix = Date().timeIntervalSince1970
            recentAccelMagnitudes.removeAll(keepingCapacity: true)
            recentGyroMagnitudes.removeAll(keepingCapacity: true)
            isArmed = false
            countdownSecondsRemaining = nil
            currentFileName = csvFileURL.deletingPathExtension().lastPathComponent
            currentWatchMetadata = nil
            sampleTimingController = nil

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
            let preRollStartUnix = Date().timeIntervalSince1970
            sampleTimingController = WatchSampleTimingController(startUnixTime: plannedStartUnix)
            currentWatchMetadata = WatchRecordingMetadata(
                sessionID: sessionID,
                plannedStartUnix: plannedStartUnix,
                actualWatchStartUnix: plannedStartUnix,
                requestedDeviceMotionInterval: configuration.requestedDeviceMotionInterval,
                attitudeReferenceFrame: attitudeReferenceFrameName,
                createdUnix: preRollStartUnix
            )

            if let recorder {
                recorder.record(atTime: recorder.deviceCurrentTime + max(0, plannedStartUnix - preRollStartUnix))
            }

            motionManager.deviceMotionUpdateInterval = configuration.requestedDeviceMotionInterval
            motionManager.startDeviceMotionUpdates(using: attitudeReferenceFrame, to: motionQueue) { [weak self] motion, error in
                guard let self else { return }

                if let error {
                    DispatchQueue.main.async {
                        self.setStatus("Motion error: \(error.localizedDescription)")
                        self.stopRecording()
                    }
                    return
                }

                guard let motion else { return }
                self.appendSample(motion)
            }

            try saveCurrentWatchMetadata()
            isRecording = true

            if plannedStartUnix > Date().timeIntervalSince1970 {
                isArmed = true
                setStatus("Armed, starting soon")
                startCountdown(to: plannedStartUnix)
                let delayNanoseconds = UInt64((plannedStartUnix - Date().timeIntervalSince1970) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            isArmed = false
            countdownSecondsRemaining = nil
            if configuration.coordinatesWithPhoneRecording {
                transport.sendRecordingControl(action: .start, sessionID: sessionID)
            }
            statusMessage = configuration.recordsAudio ? "Recording motion + audio" : "Recording motion"
        } catch {
            isArmed = false
            countdownSecondsRemaining = nil
            cleanupIncompleteSession()
            setStatus("Failed to start: \(error.localizedDescription)")
        }
    }

    private func appendSample(_ motion: CMDeviceMotion) {
        guard var sampleTimingController else { return }

        let decision = sampleTimingController.evaluate(
            motionTimestamp: motion.timestamp,
            unixNow: Date().timeIntervalSince1970
        )
        self.sampleTimingController = sampleTimingController
        guard decision.shouldKeepSample else { return }

        let timestamp = decision.sampleUnixTime
        if decision.isFirstAcceptedSample {
            updateActualWatchStartUnix(timestamp)
        }

        let acceleration = motion.userAcceleration
        let gyro = motion.rotationRate
        let gravity = motion.gravity
        let attitude = motion.attitude
        let quaternion = attitude.quaternion
        let magneticField = motion.magneticField.field

        let accelMagnitude = magnitude3(x: acceleration.x, y: acceleration.y, z: acceleration.z)
        let gyroMagnitude = magnitude3(x: gyro.x, y: gyro.y, z: gyro.z)

        let line = configuration.csvFields
            .map {
                csvValue(
                    for: $0,
                    timestamp: timestamp,
                    acceleration: acceleration,
                    gyro: gyro,
                    gravity: gravity,
                    quaternion: quaternion,
                    heading: motion.heading,
                    magneticField: magneticField
                )
            }
            .joined(separator: ",")
            .appending("\n")

        let handle = fileHandle

        fileQueue.async {
            guard let bytes = line.data(using: .utf8) else { return }

            do {
                try handle?.seekToEnd()
                try handle?.write(contentsOf: bytes)

                let now = Date().timeIntervalSince1970
                if now - self.lastFileSynchronizationUnix >= self.configuration.fileSynchronizationInterval {
                    try handle?.synchronize()
                    self.lastFileSynchronizationUnix = now
                }
            } catch {
                DispatchQueue.main.async {
                    self.setStatus("Write error: \(error.localizedDescription)")
                }
            }
        }

        DispatchQueue.main.async {
            self.latestAccelMagnitude = accelMagnitude
            self.latestGyroMagnitude = gyroMagnitude
            self.sampleCount += 1

            self.recentAccelMagnitudes.append(accelMagnitude)
            self.recentGyroMagnitudes.append(gyroMagnitude)

            if self.recentAccelMagnitudes.count > self.configuration.maxHistorySamples {
                self.recentAccelMagnitudes.removeFirst(self.recentAccelMagnitudes.count - self.configuration.maxHistorySamples)
            }
            if self.recentGyroMagnitudes.count > self.configuration.maxHistorySamples {
                self.recentGyroMagnitudes.removeFirst(self.recentGyroMagnitudes.count - self.configuration.maxHistorySamples)
            }
        }
    }

    private func magnitude3(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
    }

    private func csvValue(
        for field: WatchRecordingCSVField,
        timestamp: Double,
        acceleration: CMAcceleration,
        gyro: CMRotationRate,
        gravity: CMAcceleration,
        quaternion: CMQuaternion,
        heading: Double,
        magneticField: CMMagneticField
    ) -> String {
        switch field {
        case .timestamp:
            return formatCSVValue(timestamp, fractionDigits: 6)
        case .ax:
            return formatCSVValue(acceleration.x, fractionDigits: 6)
        case .ay:
            return formatCSVValue(acceleration.y, fractionDigits: 6)
        case .az:
            return formatCSVValue(acceleration.z, fractionDigits: 6)
        case .gx:
            return formatCSVValue(gyro.x, fractionDigits: 6)
        case .gy:
            return formatCSVValue(gyro.y, fractionDigits: 6)
        case .gz:
            return formatCSVValue(gyro.z, fractionDigits: 6)
        case .grx:
            return formatCSVValue(gravity.x, fractionDigits: 6)
        case .gry:
            return formatCSVValue(gravity.y, fractionDigits: 6)
        case .grz:
            return formatCSVValue(gravity.z, fractionDigits: 6)
        case .qw:
            return formatCSVValue(quaternion.w, fractionDigits: 9)
        case .qx:
            return formatCSVValue(quaternion.x, fractionDigits: 9)
        case .qy:
            return formatCSVValue(quaternion.y, fractionDigits: 9)
        case .qz:
            return formatCSVValue(quaternion.z, fractionDigits: 9)
        case .heading:
            return formatCSVValue(heading, fractionDigits: 9)
        case .mX:
            return formatCSVValue(magneticField.x, fractionDigits: 9)
        case .mY:
            return formatCSVValue(magneticField.y, fractionDigits: 9)
        case .mZ:
            return formatCSVValue(magneticField.z, fractionDigits: 9)
        }
    }

    private func formatCSVValue(_ value: Double, fractionDigits: Int) -> String {
        String(
            format: "%.\(fractionDigits)f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private func requestAudioPermission() async -> Bool {
        let application = AVAudioApplication.shared

        switch application.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func createRecordingFileURL(sessionID: String, fileExtension: String) throws -> URL {
        let documentsDirectory = WatchPendingRecordingStore.recordingsDirectoryURL()
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)

        return documentsDirectory.appendingPathComponent("recording_\(sessionID).\(fileExtension)")
    }

    private func createMetadataFileURL(sessionID: String) throws -> URL {
        let documentsDirectory = WatchPendingRecordingStore.recordingsDirectoryURL()
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)

        return documentsDirectory.appendingPathComponent("recording_\(sessionID).watch.json")
    }

    private func prepareLogFile(at url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let header = configuration.csvFields
            .map(\.rawValue)
            .joined(separator: ",")
            .appending("\n")
        try header.write(to: url, atomically: true, encoding: .utf8)
        return try FileHandle(forWritingTo: url)
    }

    private func prepareAudioRecorder(at url: URL) throws -> AVAudioRecorder {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        return recorder
    }

    private func saveWatchMetadata(to url: URL, metadata: WatchRecordingMetadata) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private func saveCurrentWatchMetadata() throws {
        guard let currentMetadataFileURL, let currentWatchMetadata else { return }
        try saveWatchMetadata(to: currentMetadataFileURL, metadata: currentWatchMetadata)
    }

    private func updateActualWatchStartUnix(_ actualWatchStartUnix: Double) {
        guard let currentWatchMetadata else { return }

        self.currentWatchMetadata = WatchRecordingMetadata(
            sessionID: currentWatchMetadata.sessionID,
            plannedStartUnix: currentWatchMetadata.plannedStartUnix,
            actualWatchStartUnix: actualWatchStartUnix,
            requestedDeviceMotionInterval: currentWatchMetadata.requestedDeviceMotionInterval,
            attitudeReferenceFrame: currentWatchMetadata.attitudeReferenceFrame,
            createdUnix: currentWatchMetadata.createdUnix,
            applicationPayloads: currentWatchMetadata.applicationPayloads
        )

        do {
            try saveCurrentWatchMetadata()
        } catch {
            setStatus("Metadata write error: \(error.localizedDescription)")
        }
    }

    private func startCountdown(to plannedStartUnix: Double) {
        Task { [weak self] in
            guard let self else { return }

            while self.isArmed {
                let remaining = max(0, plannedStartUnix - Date().timeIntervalSince1970)

                await MainActor.run {
                    self.countdownSecondsRemaining = remaining
                }

                if remaining <= 0.05 {
                    break
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            await MainActor.run {
                if self.isArmed {
                    self.countdownSecondsRemaining = 0
                }
            }
        }
    }

    private func cleanupIncompleteSession() {
        let fileManager = FileManager.default

        if let currentCSVFileURL {
            try? fileManager.removeItem(at: currentCSVFileURL)
        }
        if let currentAudioFileURL {
            try? fileManager.removeItem(at: currentAudioFileURL)
        }

        currentCSVFileURL = nil
        currentAudioFileURL = nil
        currentMetadataFileURL = nil
        currentSessionID = nil
        currentAttitudeReferenceFrameName = nil
        audioRecorder = nil
        currentWatchMetadata = nil
        fileHandle = nil
        sampleTimingController = nil
    }

    private static func preferredAttitudeReferenceFrame() -> CMAttitudeReferenceFrame {
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()

        if availableFrames.contains(.xMagneticNorthZVertical) {
            return .xMagneticNorthZVertical
        }
        if availableFrames.contains(.xArbitraryCorrectedZVertical) {
            return .xArbitraryCorrectedZVertical
        }
        return .xArbitraryZVertical
    }

    private static func name(for frame: CMAttitudeReferenceFrame) -> String {
        switch frame {
        case .xArbitraryZVertical:
            return "xArbitraryZVertical"
        case .xArbitraryCorrectedZVertical:
            return "xArbitraryCorrectedZVertical"
        case .xMagneticNorthZVertical:
            return "xMagneticNorthZVertical"
        case .xTrueNorthZVertical:
            return "xTrueNorthZVertical"
        default:
            return "unknown"
        }
    }

    private static func makeSessionID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func setStatus(_ message: String) {
        if Thread.isMainThread {
            statusMessage = message
        } else {
            DispatchQueue.main.async {
                self.statusMessage = message
            }
        }
    }
}

extension WatchRecordingCoordinator: @unchecked Sendable {}
