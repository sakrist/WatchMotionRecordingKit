import Foundation
import OSLog
import WatchConnectivity

public protocol WatchRecordingTransport: AnyObject {
    var fileTransferCompletionHandler: ((URL, Error?) -> Void)? { get set }
    var pendingTransferRetryRequestHandler: (() -> Void)? { get set }

    func activate()
    func cancelOutstandingFileTransfers()
    func transferRecordingFiles(sessionID: String, fileURLs: [URL])
    func sendRecordingControl(action: RecordingControlAction, sessionID: String)
    func requestScheduledStart(sessionID: String, leadTime: TimeInterval) async -> ScheduledStartResponse?
}

public final class WatchConnectivityRecordingTransport: NSObject, WatchRecordingTransport, WCSessionDelegate {
    public var fileTransferCompletionHandler: ((URL, Error?) -> Void)?
    public var pendingTransferRetryRequestHandler: (() -> Void)?
    private let logger = Logger(subsystem: "com.sakrist.WatchMotionRecordingKit", category: "WatchTransfer")

    public override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        logger.info("WCSession activate requested")
    }

    public func cancelOutstandingFileTransfers() {
        guard WCSession.isSupported() else { return }

        let transfers = WCSession.default.outstandingFileTransfers
        for transfer in transfers {
            transfer.cancel()
        }
        logger.info("Cancelled outstanding file transfers: \(transfers.count)")
    }

    public func transferRecordingFiles(sessionID: String, fileURLs: [URL]) {
        guard WCSession.isSupported() else {
            logger.error("WCSession unsupported; cannot transfer session \(sessionID, privacy: .public)")
            return
        }

        let session = WCSession.default
        if session.activationState != .activated {
            session.delegate = self
            session.activate()
            logger.info("WCSession not activated; activation requested before transfer for session \(sessionID, privacy: .public)")
        }

        let outstandingPaths = Set(session.outstandingFileTransfers.map(\.file.fileURL.path))
        logger.info("Transfer requested for session \(sessionID, privacy: .public), files \(fileURLs.count), outstanding \(outstandingPaths.count), activation \(String(describing: session.activationState), privacy: .public)")

        for fileURL in fileURLs where !outstandingPaths.contains(fileURL.path) {
            session.transferFile(fileURL, metadata: [
                "fileName": fileURL.lastPathComponent,
                "sessionID": sessionID,
            ])
            logger.info("Queued file transfer \(fileURL.lastPathComponent, privacy: .public)")
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
        if let error {
            logger.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.info("WCSession activation completed: \(String(describing: activationState), privacy: .public)")
        }
    }

    public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let fileURL = fileTransfer.file.fileURL

        if error == nil {
            WatchPendingRecordingStore.markFileSynced(fileURL)
            WatchPendingRecordingStore.trimStoredSessions()
            logger.info("File transfer finished and local file marked synced: \(fileURL.lastPathComponent, privacy: .public)")
        } else if let error {
            logger.error("File transfer failed for \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        fileTransferCompletionHandler?(fileURL, error)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message[WatchRecordingCommand.commandKey] as? String == WatchRecordingCommand.retryPendingTransfers else {
            return
        }

        logger.info("Received retry pending transfers command")
        pendingTransferRetryRequestHandler?()
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
