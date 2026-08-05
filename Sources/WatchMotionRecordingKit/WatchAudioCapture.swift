import AVFoundation
import Foundation

/// Owns optional Watch microphone recording for one motion session.
///
/// Audio is a companion file, not part of either binary motion stream. The class
/// stays concrete and internal because the coordinator needs only permission,
/// scheduled start, and stop operations.
final class WatchAudioCapture {
    private var recorder: AVAudioRecorder?

    /// Returns the current microphone decision, requesting it when still undecided.
    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
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

    /// Prepares AAC recording and schedules it against the recorder's device clock.
    ///
    /// Scheduling avoids main-thread or task wake-up delay at the shared Unix start.
    func start(
        at url: URL,
        plannedStartUnix: TimeInterval,
        preparedUnix: TimeInterval
    ) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        recorder.prepareToRecord()

        let delay = max(0, plannedStartUnix - preparedUnix)
        guard recorder.record(atTime: recorder.deviceCurrentTime + delay) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.recorder = recorder
    }

    /// Finishes the audio file and releases the active recording audio session.
    func stop() {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
