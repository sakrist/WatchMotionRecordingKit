import Foundation
import WatchConnectivity

public protocol WatchRecordingTransport: AnyObject {
    func activate()
    func transferRecordingFiles(sessionID: String, fileURLs: [URL])
    func sendRecordingControl(action: RecordingControlAction, sessionID: String)
    func requestScheduledStart(sessionID: String, leadTime: TimeInterval) async -> ScheduledStartResponse?
}

public final class WatchConnectivityRecordingTransport: NSObject, WatchRecordingTransport, WCSessionDelegate {
    public override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    public func transferRecordingFiles(sessionID: String, fileURLs: [URL]) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        if session.activationState != .activated {
            session.delegate = self
            session.activate()
        }

        for fileURL in fileURLs {
            session.transferFile(fileURL, metadata: [
                "fileName": fileURL.lastPathComponent,
                "sessionID": sessionID,
            ])
        }
    }

    public func sendRecordingControl(action: RecordingControlAction, sessionID: String) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        let message = RecordingControlMessage(action: action, sessionID: sessionID)
        session.sendMessage(message.dictionaryRepresentation, replyHandler: nil, errorHandler: nil)
    }

    public func requestScheduledStart(sessionID: String, leadTime: TimeInterval) async -> ScheduledStartResponse? {
        guard WCSession.isSupported() else { return nil }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return nil }

        return await withCheckedContinuation { continuation in
            let message = RecordingControlMessage(
                action: .prepare,
                sessionID: sessionID,
                leadTime: leadTime
            )

            session.sendMessage(message.dictionaryRepresentation, replyHandler: { reply in
                continuation.resume(returning: ScheduledStartResponse(dictionary: reply))
            }, errorHandler: { _ in
                continuation.resume(returning: nil)
            })
        }
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Transfers are queued by the system when the counterpart is unavailable.
    }

#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        // Required on iPhone and harmless on watchOS.
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
}
