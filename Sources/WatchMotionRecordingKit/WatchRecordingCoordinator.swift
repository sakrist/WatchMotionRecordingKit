import Foundation
import CoreMotion
import Combine
import AVFoundation

public struct WatchRecordingConfiguration: Sendable, Equatable {
    public let requestedDeviceMotionInterval: TimeInterval
    public let scheduledLeadTime: TimeInterval
    public let maxHistorySamples: Int
    public let recordsAudio: Bool

    public init(
        requestedDeviceMotionInterval: TimeInterval = 1.0 / 200.0,
        scheduledLeadTime: TimeInterval = 2.0,
        maxHistorySamples: Int = 150,
        recordsAudio: Bool = true
    ) {
        self.requestedDeviceMotionInterval = requestedDeviceMotionInterval
        self.scheduledLeadTime = scheduledLeadTime
        self.maxHistorySamples = maxHistorySamples
        self.recordsAudio = recordsAudio
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

    private let configuration: WatchRecordingConfiguration
    private let motionManager: CMMotionManager
    private let transport: any WatchRecordingTransport
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
    private var audioRecorder: AVAudioRecorder?
    private var currentWatchMetadata: WatchRecordingMetadata?
    private var sampleTimingController: WatchSampleTimingController?

    public init(
        configuration: WatchRecordingConfiguration = WatchRecordingConfiguration(),
        motionManager: CMMotionManager = CMMotionManager(),
        transport: any WatchRecordingTransport = WatchConnectivityRecordingTransport()
    ) {
        self.configuration = configuration
        self.motionManager = motionManager
        self.transport = transport
        transport.activate()
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
            transport.sendRecordingControl(action: .stop, sessionID: sessionID)
            let files = [currentCSVFileURL, currentAudioFileURL, currentMetadataFileURL].compactMap { $0 }
            transport.transferRecordingFiles(sessionID: sessionID, fileURLs: files)
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
            audioRecorder = recorder

            sampleCount = 0
            latestAccelMagnitude = 0
            latestGyroMagnitude = 0
            recentAccelMagnitudes.removeAll(keepingCapacity: true)
            recentGyroMagnitudes.removeAll(keepingCapacity: true)
            isArmed = false
            countdownSecondsRemaining = nil
            currentFileName = csvFileURL.deletingPathExtension().lastPathComponent
            currentWatchMetadata = nil
            sampleTimingController = nil

            let scheduledStart = await transport.requestScheduledStart(
                sessionID: sessionID,
                leadTime: configuration.scheduledLeadTime
            )

            let plannedStartUnix = scheduledStart?.plannedStartUnix ?? Date().timeIntervalSince1970
            let preRollStartUnix = Date().timeIntervalSince1970
            sampleTimingController = WatchSampleTimingController(startUnixTime: plannedStartUnix)
            currentWatchMetadata = WatchRecordingMetadata(
                sessionID: sessionID,
                plannedStartUnix: plannedStartUnix,
                actualWatchStartUnix: plannedStartUnix,
                requestedDeviceMotionInterval: configuration.requestedDeviceMotionInterval,
                createdUnix: preRollStartUnix
            )

            if let recorder {
                recorder.record(atTime: recorder.deviceCurrentTime + max(0, plannedStartUnix - preRollStartUnix))
            }

            motionManager.deviceMotionUpdateInterval = configuration.requestedDeviceMotionInterval
            motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
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
            transport.sendRecordingControl(action: .start, sessionID: sessionID)
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

        let accelMagnitude = magnitude3(x: acceleration.x, y: acceleration.y, z: acceleration.z)
        let gyroMagnitude = magnitude3(x: gyro.x, y: gyro.y, z: gyro.z)

        let line = String(
            format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            timestamp,
            acceleration.x, acceleration.y, acceleration.z,
            gyro.x, gyro.y, gyro.z,
            gravity.x, gravity.y, gravity.z
        )

        let handle = fileHandle

        fileQueue.async {
            guard let bytes = line.data(using: .utf8) else { return }

            do {
                try handle?.seekToEnd()
                try handle?.write(contentsOf: bytes)
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
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return documentsDirectory.appendingPathComponent("recording_\(sessionID).\(fileExtension)")
    }

    private func createMetadataFileURL(sessionID: String) throws -> URL {
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return documentsDirectory.appendingPathComponent("recording_\(sessionID).watch.json")
    }

    private func prepareLogFile(at url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let header = "timestamp,ax,ay,az,gx,gy,gz,grx,gry,grz\n"
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
            createdUnix: currentWatchMetadata.createdUnix
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
        audioRecorder = nil
        currentWatchMetadata = nil
        fileHandle = nil
        sampleTimingController = nil
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
