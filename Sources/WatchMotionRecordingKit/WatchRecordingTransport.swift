import Foundation
import OSLog
import WatchConnectivity

/// Communication boundary between recording logic and WatchConnectivity.
///
/// The protocol keeps the coordinator testable without hiding recording behavior
/// behind a larger service hierarchy.
public protocol WatchRecordingTransport: AnyObject {
    /// Called once WatchConnectivity finishes attempting one file transfer.
    var fileTransferCompletionHandler: ((URL, Error?) -> Void)? { get set }

    /// Called when the phone asks the Watch to retry locally retained files.
    var pendingTransferRetryRequestHandler: (() -> Void)? { get set }

    /// Activates the underlying communication session.
    func activate()

    /// Cancels currently queued file transfers without deleting local files.
    func cancelOutstandingFileTransfers()

    /// Queues completed files for background delivery to the iPhone.
    func transferRecordingFiles(sessionID: String, fileURLs: [URL])

    /// Sends an immediate start or stop marker to the reachable iPhone app.
    func sendRecordingControl(action: RecordingControlAction, sessionID: String)

    /// Asks the iPhone to begin video pre-roll and choose a shared future start.
    func requestScheduledStart(sessionID: String, leadTime: TimeInterval) async -> ScheduledStartResponse?
}

/// WatchConnectivity implementation used by the real Watch app.
///
/// Control messages require the iPhone to be reachable. Completed file transfer
/// uses WatchConnectivity's queued background mechanism and can finish later.
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

    /// Queues only files that are not already represented by an outstanding transfer.
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

    /// Sends a live control marker; unlike files, this cannot wait for an unreachable phone.
    public func sendRecordingControl(action: RecordingControlAction, sessionID: String) {
        guard WCSession.isSupported() else {
            logger.error("Cannot send \(action.rawValue, privacy: .public) control; WatchConnectivity is unsupported. session=\(sessionID, privacy: .public)")
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            logger.error("Cannot send \(action.rawValue, privacy: .public) control; iPhone is unavailable. session=\(sessionID, privacy: .public) activation=\(String(describing: session.activationState), privacy: .public) reachable=\(session.isReachable, privacy: .public)")
            return
        }

        let message = RecordingControlMessage(action: action, sessionID: sessionID)
        logger.info("Sending \(action.rawValue, privacy: .public) recording control. session=\(sessionID, privacy: .public)")
        session.sendMessage(message.dictionaryRepresentation, replyHandler: nil) { [logger] error in
            logger.error("Recording control failed. action=\(action.rawValue, privacy: .public) session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends `.prepare` and waits for the iPhone's acceptance and planned start time.
    ///
    /// An accepted reply means the phone has started video pre-roll. A missing or
    /// rejected reply prevents the Watch session when synchronized video is required.
    public func requestScheduledStart(sessionID: String, leadTime: TimeInterval) async -> ScheduledStartResponse? {
        guard WCSession.isSupported() else {
            logger.error("Cannot prepare iPhone video; WatchConnectivity is unsupported. session=\(sessionID, privacy: .public)")
            return nil
        }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            logger.error("Cannot prepare iPhone video; iPhone is unavailable. session=\(sessionID, privacy: .public) activation=\(String(describing: session.activationState), privacy: .public) reachable=\(session.isReachable, privacy: .public)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let message = RecordingControlMessage(
                action: .prepare,
                sessionID: sessionID,
                leadTime: leadTime
            )

            self.logger.info("Requesting iPhone video pre-roll. session=\(sessionID, privacy: .public) leadTime=\(leadTime, privacy: .public)s")
            session.sendMessage(message.dictionaryRepresentation, replyHandler: { reply in
                let response = ScheduledStartResponse(dictionary: reply)
                self.logger.info("Received iPhone video pre-roll reply. session=\(sessionID, privacy: .public) accepted=\(response?.accepted ?? false, privacy: .public)")
                continuation.resume(returning: response)
            }, errorHandler: { error in
                self.logger.error("iPhone video pre-roll request failed. session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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

    /// Marks a local file synchronized only after WatchConnectivity reports success.
    public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let fileURL = fileTransfer.file.fileURL

        if error == nil {
            WatchPendingRecordingStore.markFileSynced(fileURL)
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
