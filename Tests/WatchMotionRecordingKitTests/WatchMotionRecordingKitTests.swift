import XCTest
@testable import WatchMotionRecordingKit

final class WatchMotionRecordingKitTests: XCTestCase {
    func testRecordingControlMessageRoundTripsThroughDictionary() {
        let message = RecordingControlMessage(
            action: .prepare,
            sessionID: "20260331_181828",
            leadTime: 2.0
        )

        let decoded = RecordingControlMessage(dictionary: message.dictionaryRepresentation)

        XCTAssertEqual(decoded, message)
    }

    func testScheduledStartResponseRoundTripsThroughDictionary() {
        let response = ScheduledStartResponse(
            plannedStartUnix: 1774977510.7181191,
            accepted: true
        )

        let decoded = ScheduledStartResponse(dictionary: response.dictionaryRepresentation)

        XCTAssertEqual(decoded, response)
    }

    func testUnixTimeProjectorAnchorsFirstSampleAndProjectsLaterSamples() {
        var projector = UnixTimeProjector()

        let first = projector.project(motionTimestamp: 1234.0, unixNow: 1710000000.5)
        let second = projector.project(motionTimestamp: 1234.015, unixNow: 999)

        XCTAssertEqual(first, 1710000000.5, accuracy: 0.000_001)
        XCTAssertEqual(second, 1710000000.515, accuracy: 0.000_001)
    }

    func testScheduledSampleGateRejectsPrerollAndMarksFirstAcceptedSample() throws {
        var gate = ScheduledSampleGate(startUnixTime: 100.0)

        let early = gate.evaluate(sampleUnixTime: 99.99)
        let first = gate.evaluate(sampleUnixTime: 100.001)
        let second = gate.evaluate(sampleUnixTime: 100.010)

        XCTAssertFalse(early.shouldKeepSample)
        XCTAssertFalse(early.isFirstAcceptedSample)
        XCTAssertTrue(first.shouldKeepSample)
        XCTAssertTrue(first.isFirstAcceptedSample)
        XCTAssertTrue(second.shouldKeepSample)
        XCTAssertFalse(second.isFirstAcceptedSample)
        XCTAssertEqual(try XCTUnwrap(gate.firstAcceptedSampleUnixTime), 100.001, accuracy: 0.000_001)
    }

    func testWatchSampleTimingControllerCombinesProjectionAndGate() {
        var controller = WatchSampleTimingController(startUnixTime: 200.01)

        let first = controller.evaluate(motionTimestamp: 10.0, unixNow: 200.0)
        let second = controller.evaluate(motionTimestamp: 10.02, unixNow: 999.0)

        XCTAssertFalse(first.shouldKeepSample)
        XCTAssertTrue(second.shouldKeepSample)
        XCTAssertTrue(second.isFirstAcceptedSample)
        XCTAssertEqual(second.sampleUnixTime, 200.02, accuracy: 0.000_001)
    }

    func testImmediateWatchOnlySessionKeepsSamplesFromStartThroughEnd() {
        var controller = WatchSampleTimingController(startUnixTime: 1_000.0)

        let decisions = stride(from: 0.0, through: 6.0, by: 1.0).map { offset in
            controller.evaluate(
                motionTimestamp: 50.0 + offset,
                unixNow: 1_000.0 + offset
            )
        }

        XCTAssertEqual(decisions.count, 7)
        XCTAssertTrue(decisions.allSatisfy(\.shouldKeepSample))
        XCTAssertTrue(decisions[0].isFirstAcceptedSample)
        XCTAssertFalse(decisions[6].isFirstAcceptedSample)
        XCTAssertEqual(decisions[0].sampleUnixTime, 1_000.0, accuracy: 0.000_001)
        XCTAssertEqual(decisions[6].sampleUnixTime, 1_006.0, accuracy: 0.000_001)
    }

    func testPhoneCoordinatedSessionDropsSamplesBeforePlannedStart() {
        var controller = WatchSampleTimingController(startUnixTime: 1_002.0)

        let decisions = stride(from: 0.0, through: 6.0, by: 1.0).map { offset in
            controller.evaluate(
                motionTimestamp: 50.0 + offset,
                unixNow: 1_000.0 + offset
            )
        }

        XCTAssertFalse(decisions[0].shouldKeepSample)
        XCTAssertFalse(decisions[1].shouldKeepSample)
        XCTAssertTrue(decisions[2].shouldKeepSample)
        XCTAssertTrue(decisions[2].isFirstAcceptedSample)
        XCTAssertTrue(decisions[6].shouldKeepSample)
        XCTAssertEqual(decisions[6].sampleUnixTime, 1_006.0, accuracy: 0.000_001)
    }

    func testConfigurationCanDisablePhoneRecordingCoordination() {
        let configuration = WatchRecordingConfiguration(
            recordsAudio: false,
            coordinatesWithPhoneRecording: false
        )

        XCTAssertFalse(configuration.recordsAudio)
        XCTAssertFalse(configuration.coordinatesWithPhoneRecording)
        XCTAssertEqual(configuration.retainedSessionLimit, 10)
    }

    func testConfigurationDefaultsToCurrentCSVFields() {
        let configuration = WatchRecordingConfiguration()

        XCTAssertEqual(
            configuration.csvFields.map(\.rawValue),
            [
                "timestamp",
                "ax",
                "ay",
                "az",
                "gx",
                "gy",
                "gz",
                "grx",
                "gry",
                "grz",
                "qw",
                "qx",
                "qy",
                "qz",
                "heading",
                "mX",
                "mY",
                "mZ",
            ]
        )
    }

    func testPendingSessionsKeepMetadataOnlyRetriesAfterCSVTransfers() throws {
        let sessionID = "unit_retry_metadata_only_\(UUID().uuidString)"
        let directoryURL = WatchPendingRecordingStore.recordingsDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let metadataURL = directoryURL.appendingPathComponent("recording_\(sessionID).watch.json")
        defer {
            try? FileManager.default.removeItem(at: metadataURL)
        }

        try #"{"applicationPayloads":{"camanlab.strikeRatings":"{\"ratings\":[]}"}}"#
            .write(to: metadataURL, atomically: true, encoding: .utf8)

        let pendingSession = WatchPendingRecordingStore.pendingSessions()
            .first { $0.sessionID == sessionID }

        XCTAssertEqual(pendingSession?.fileURLs, [metadataURL])
    }

    func testSyncedMarkersHideFilesUntilReset() throws {
        let sessionID = "unit_synced_marker_\(UUID().uuidString)"
        let directoryURL = WatchPendingRecordingStore.recordingsDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let csvURL = directoryURL.appendingPathComponent("recording_\(sessionID).csv")
        let markerURL = directoryURL.appendingPathComponent(".\(csvURL.lastPathComponent).synced")
        defer {
            try? FileManager.default.removeItem(at: csvURL)
            try? FileManager.default.removeItem(at: markerURL)
        }

        try "timestamp,ax,ay,az,gx,gy,gz,grx,gry,grz\n"
            .write(to: csvURL, atomically: true, encoding: .utf8)

        XCTAssertNotNil(WatchPendingRecordingStore.pendingSessions().first { $0.sessionID == sessionID })

        WatchPendingRecordingStore.markFileSynced(csvURL)
        XCTAssertNil(WatchPendingRecordingStore.pendingSessions().first { $0.sessionID == sessionID })

        WatchPendingRecordingStore.resetSyncMarkers()
        XCTAssertNotNil(WatchPendingRecordingStore.pendingSessions().first { $0.sessionID == sessionID })
    }
}
