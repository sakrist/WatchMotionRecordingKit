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

    func testScheduledSampleGateRejectsPrerollAndMarksFirstAcceptedSample() {
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
        XCTAssertEqual(gate.firstAcceptedSampleUnixTime, 100.001, accuracy: 0.000_001)
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
}
