import Foundation

/// Session-checked lifecycle transitions for one Watch recording at a time.
struct WatchRecordingLifecycle: Equatable {
    enum Phase: Equatable {
        case idle
        case starting(sessionID: String)
        case recording(sessionID: String)
        case stopping(sessionID: String)
    }

    enum StopAction: Equatable {
        case cancelStartup(sessionID: String)
        case finishRecording(sessionID: String)
    }

    private(set) var phase: Phase = .idle

    mutating func beginStartup(sessionID: String) -> Bool {
        guard phase == .idle else { return false }
        phase = .starting(sessionID: sessionID)
        return true
    }

    func isStarting(sessionID: String) -> Bool {
        phase == .starting(sessionID: sessionID)
    }

    mutating func completeStartup(sessionID: String) -> Bool {
        guard isStarting(sessionID: sessionID) else { return false }
        phase = .recording(sessionID: sessionID)
        return true
    }

    mutating func beginStop() -> StopAction? {
        switch phase {
        case .idle, .stopping:
            return nil
        case .starting(let sessionID):
            phase = .idle
            return .cancelStartup(sessionID: sessionID)
        case .recording(let sessionID):
            phase = .stopping(sessionID: sessionID)
            return .finishRecording(sessionID: sessionID)
        }
    }

    mutating func fail(sessionID: String) -> Bool {
        switch phase {
        case .starting(let activeSessionID),
             .recording(let activeSessionID),
             .stopping(let activeSessionID):
            guard activeSessionID == sessionID else { return false }
            phase = .idle
            return true
        default:
            return false
        }
    }

    mutating func finishStop(sessionID: String) -> Bool {
        guard phase == .stopping(sessionID: sessionID) else { return false }
        phase = .idle
        return true
    }
}
