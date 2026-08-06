import Foundation
import XCTest
@testable import WatchMotionRecordingKit

final class WatchMotionRecordingKitTests: XCTestCase {
    func testRecordingControlMessageRoundTripsThroughDictionary() {
        let message = RecordingControlMessage(
            action: .prepare,
            sessionID: "00112233-4455-4677-8899-aabbccddeeff",
            leadTime: 2.0
        )

        XCTAssertEqual(RecordingControlMessage(dictionary: message.dictionaryRepresentation), message)
    }

    func testScheduledStartResponseRoundTripsThroughDictionary() {
        let response = ScheduledStartResponse(plannedStartUnix: 1_774_977_510.718_119_1, accepted: true)

        XCTAssertEqual(ScheduledStartResponse(dictionary: response.dictionaryRepresentation), response)
    }

    func testLocalOnlyRecordingNeverAddsScheduledStartDelay() {
        let delay = WatchRecordingStartTiming.scheduledDelay(
            coordinatesWithPhoneRecording: false,
            plannedStartUnix: 102,
            nowUnix: 100
        )

        XCTAssertEqual(delay, 0)
    }

    func testPhoneCoordinatedRecordingWaitsOnlyForRemainingLeadTime() {
        XCTAssertEqual(
            WatchRecordingStartTiming.scheduledDelay(
                coordinatesWithPhoneRecording: true,
                plannedStartUnix: 102,
                nowUnix: 100
            ),
            2
        )
        XCTAssertEqual(
            WatchRecordingStartTiming.scheduledDelay(
                coordinatesWithPhoneRecording: true,
                plannedStartUnix: 99,
                nowUnix: 100
            ),
            0
        )
    }

    func testSharedUnixTimeProjectorPreservesIndependentSampleTimes() {
        var projector = UnixTimeProjector()

        let deviceTime = projector.project(
            motionTimestamp: 1_008.0,
            unixNow: 1_700_000_010.0,
            systemUptimeNow: 1_010.0
        )
        let delayedRawTime = projector.project(
            motionTimestamp: 1_008.001_25,
            unixNow: 1_700_000_020.0,
            systemUptimeNow: 1_020.0
        )

        XCTAssertEqual(deviceTime, 1_700_000_008.0, accuracy: 0.000_001)
        XCTAssertEqual(delayedRawTime, 1_700_000_008.001_25, accuracy: 0.000_001)
    }

    func testScheduledGatesCanShareProjectionWithoutSharingAcceptanceState() {
        var projector = UnixTimeProjector()
        var deviceGate = ScheduledSampleGate(startUnixTime: 100.0)
        var rawGate = ScheduledSampleGate(startUnixTime: 100.0)

        let deviceTime = projector.project(motionTimestamp: 10, unixNow: 99.995)
        let rawTime = projector.project(motionTimestamp: 10.006, unixNow: 999)
        let laterDeviceTime = projector.project(motionTimestamp: 10.010, unixNow: 999)

        XCTAssertFalse(deviceGate.evaluate(sampleUnixTime: deviceTime).shouldKeepSample)
        XCTAssertTrue(rawGate.evaluate(sampleUnixTime: rawTime).isFirstAcceptedSample)
        XCTAssertTrue(deviceGate.evaluate(sampleUnixTime: laterDeviceTime).isFirstAcceptedSample)
    }

    func testDeviceMotionHeaderHasExactLittleEndianLayout() throws {
        let sessionID = "00112233-4455-6677-8899-AABBCCDDEEFF"
        let header = WatchMotionBinaryHeader(
            stream: .deviceMotion,
            sampleCount: 0x0102_0304_0506_0708,
            sessionID: sessionID,
            actualFrequencyHz: 200
        )

        let bytes = try header.encoded()

        XCTAssertEqual(bytes.count, 64)
        XCTAssertEqual(Data(bytes[0..<8]), Data("WMRDM001".utf8))
        XCTAssertEqual(Array(bytes[8..<12]), [1, 0, 60, 0])
        XCTAssertEqual(Array(bytes[12..<20]), [8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(Array(bytes[20..<36]), [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255])
        XCTAssertEqual(Array(bytes[36..<38]), [200, 0])
        XCTAssertEqual(Array(bytes[38..<64]), [UInt8](repeating: 0, count: 26))
        XCTAssertEqual(try WatchMotionBinaryHeader.decode(from: bytes), header)
    }

    func testHeaderRejectsTextualSessionIdentity() {
        let header = WatchMotionBinaryHeader(
            stream: .deviceMotion,
            sampleCount: 0,
            sessionID: "20260722_143012",
            actualFrequencyHz: 200
        )

        XCTAssertThrowsError(try header.encoded()) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .invalidSessionID)
        }
    }

    func testRawAccelerometerHeaderHasCorrectMagic() throws {
        let header = WatchMotionBinaryHeader(
            stream: .rawAccelerometer,
            sampleCount: 2,
            sessionID: "aabbccdd-eeff-4011-8233-445566778899",
            actualFrequencyHz: 800
        )

        let bytes = try header.encoded()
        let decoded = try WatchMotionBinaryHeader.decode(from: bytes, expectedStream: .rawAccelerometer)

        XCTAssertEqual(Data(bytes[0..<8]), Data("WMRRA001".utf8))
        XCTAssertEqual(decoded.recordSize, 20)
        XCTAssertEqual(decoded.sampleCount, 2)
        XCTAssertEqual(decoded.actualFrequencyHz, 800)
    }

    func testDeviceMotionRecordHasExactFieldOrderAndLittleEndianBytes() throws {
        let record = WatchDeviceMotionBinaryRecord(
            timestampUnixMicroseconds: 0x0102_0304_0506_0708,
            userAccelerationX: 1.5,
            userAccelerationY: 2.5,
            userAccelerationZ: 3.5,
            rotationRateX: 4.0,
            rotationRateY: 5.0,
            rotationRateZ: 6.0,
            gravityX: 0.1,
            gravityY: 0.2,
            gravityZ: 0.9,
            quaternionW: 1.0,
            quaternionX: 0.0,
            quaternionY: 0.0,
            quaternionZ: 0.0
        )

        let encoded = try record.encoded()

        XCTAssertEqual(encoded.data.count, 60)
        XCTAssertEqual(Array(encoded.data[0..<8]), [8, 7, 6, 5, 4, 3, 2, 1])

        let decoded = try WatchDeviceMotionBinaryRecord.decode(from: encoded.data)

        XCTAssertEqual(decoded.timestampUnixMicroseconds, record.timestampUnixMicroseconds)
        XCTAssertEqual(decoded.userAccelerationX, record.userAccelerationX, accuracy: 0.001)
        XCTAssertEqual(decoded.userAccelerationY, record.userAccelerationY, accuracy: 0.001)
        XCTAssertEqual(decoded.userAccelerationZ, record.userAccelerationZ, accuracy: 0.001)
        XCTAssertEqual(decoded.rotationRateX, record.rotationRateX, accuracy: 0.001)
        XCTAssertEqual(decoded.rotationRateY, record.rotationRateY, accuracy: 0.001)
        XCTAssertEqual(decoded.rotationRateZ, record.rotationRateZ, accuracy: 0.001)
        XCTAssertEqual(decoded.gravityX, record.gravityX, accuracy: 0.001)
        XCTAssertEqual(decoded.gravityY, record.gravityY, accuracy: 0.001)
        XCTAssertEqual(decoded.gravityZ, record.gravityZ, accuracy: 0.001)
        XCTAssertEqual(decoded.quaternionW, record.quaternionW, accuracy: 0.001)
        XCTAssertEqual(decoded.quaternionX, record.quaternionX, accuracy: 0.001)
        XCTAssertEqual(decoded.quaternionY, record.quaternionY, accuracy: 0.001)
        XCTAssertEqual(decoded.quaternionZ, record.quaternionZ, accuracy: 0.001)
    }

    func testRawAccelerometerRecordRoundTrips() throws {
        let source = WatchRawAccelerometerBinaryRecord(
            timestampUnixMicroseconds: 1_700_000_000_123_456,
            rawAccelerationX: -19.125,
            rawAccelerationY: 0.001,
            rawAccelerationZ: 42.75
        )

        let decoded = try WatchRawAccelerometerBinaryRecord.decode(from: source.encoded().data)

        XCTAssertEqual(decoded.timestampUnixMicroseconds, source.timestampUnixMicroseconds)
        XCTAssertEqual(decoded.rawAccelerationX, source.rawAccelerationX, accuracy: 0.001)
        XCTAssertEqual(decoded.rawAccelerationY, source.rawAccelerationY, accuracy: 0.001)
        XCTAssertEqual(decoded.rawAccelerationZ, source.rawAccelerationZ, accuracy: 0.001)
    }

    func testNonFiniteValuesAreRejected() {
        XCTAssertThrowsError(try WatchDeviceMotionBinaryRecord(
            timestampUnixMicroseconds: 0,
            userAccelerationX: .nan,
            userAccelerationY: 0,
            userAccelerationZ: 0,
            rotationRateX: 0,
            rotationRateY: 0,
            rotationRateZ: 0,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 0,
            quaternionW: 0,
            quaternionX: 0,
            quaternionY: 0,
            quaternionZ: 0
        ).encoded()) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .nonFiniteValue)
        }
    }

    func testHeaderRejectsUnsupportedVersionAndMismatchedSession() throws {
        let header = WatchMotionBinaryHeader(
            stream: .deviceMotion,
            sampleCount: 0,
            sessionID: "00112233-4455-6677-8899-AABBCCDDEEFF",
            actualFrequencyHz: 200
        )
        var unsupported = try header.encoded()
        unsupported[8] = 3

        XCTAssertThrowsError(try WatchMotionBinaryHeader.decode(from: unsupported)) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .unsupportedVersion(3))
        }
        XCTAssertThrowsError(
            try WatchMotionBinaryHeader.decode(from: try header.encoded(), expectedSessionID: "other")
        ) {
            XCTAssertEqual(
                $0 as? WatchMotionBinaryError,
                .sessionMismatch(expected: "other", actual: "00112233-4455-6677-8899-aabbccddeeff")
            )
        }
    }

    func testHeaderRejectsTruncatedTailAndCountMismatch() throws {
        let header = WatchMotionBinaryHeader(
            stream: .deviceMotion,
            sampleCount: 2,
            sessionID: "00112233-4455-6677-8899-AABBCCDDEEFF",
            actualFrequencyHz: 200
        )

        XCTAssertThrowsError(try header.validateFileByteCount(64 + 60 + 1)) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .invalidFileLength(125))
        }
        XCTAssertThrowsError(try header.validateFileByteCount(64 + 60)) {
            XCTAssertEqual(
                $0 as? WatchMotionBinaryError,
                .sampleCountMismatch(expected: 2, actual: 1)
            )
        }
    }

    func testWriterFinalizesCountsHashAndRejectsTimestampRegression() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = "00112233-4455-6677-8899-aabbccddeeff"
        let url = directory.appendingPathComponent("\(sessionID).raw-accelerometer.bin")
        let writer = try WatchMotionBinaryFileWriter(
            stream: .rawAccelerometer,
            fileURL: url,
            sessionID: sessionID
        )
        try writer.append(rawRecord(timestamp: 10, x: 300))
        try writer.append(rawRecord(timestamp: 11, x: 0))

        XCTAssertThrowsError(try writer.append(rawRecord(timestamp: 9, x: 0))) {
            XCTAssertEqual(
                $0 as? WatchMotionBinaryError,
                .nonMonotonicTimestamp(previous: 11, next: 9)
            )
        }

        let summary = try writer.finalize(actualFrequencyHz: 800)
        let data = try Data(contentsOf: url)
        let header = try WatchMotionBinaryHeader.decode(from: data, expectedStream: .rawAccelerometer)

        XCTAssertEqual(summary.sampleCount, 2)
        XCTAssertEqual(summary.byteCount, UInt64(64 + (2 * 20)))
        XCTAssertEqual(summary.sha256, try WatchMotionFileIntegrity.sha256Hex(for: url))
        XCTAssertEqual(header.sampleCount, 2)
        XCTAssertEqual(header.formatVersion, WatchMotionBinaryContract.formatVersion)
        XCTAssertEqual(header.sessionID, sessionID.lowercased())
        XCTAssertEqual(try header.validateFileByteCount(data.count), 2)
    }

    func testWriterAppendsAWholeBatchAsOneLogicalPayload() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = "00112233-4455-6677-8899-aabbccddeeff"
        let url = directory.appendingPathComponent("\(sessionID).raw-accelerometer.bin")
        let writer = try WatchMotionBinaryFileWriter(
            stream: .rawAccelerometer,
            fileURL: url,
            sessionID: sessionID
        )

        let records = [
            rawRecord(timestamp: 10, x: 1),
            rawRecord(timestamp: 11, x: 2),
            rawRecord(timestamp: 12, x: 3),
        ]
        var expectedPayload = Data()
        for record in records {
            expectedPayload.append(try record.encoded().data)
        }

        try writer.append(contentsOf: records)

        let summary = try writer.finalize(actualFrequencyHz: 800)
        let data = try Data(contentsOf: url)
        let header = try WatchMotionBinaryHeader.decode(
            from: data,
            expectedStream: .rawAccelerometer,
            expectedSessionID: sessionID
        )

        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(header.sampleCount, 3)
        XCTAssertEqual(data.count, WatchMotionBinaryContract.headerByteCount + (3 * WatchMotionBinaryContract.rawAccelerometerRecordByteCount))
        XCTAssertEqual(Data(data.dropFirst(WatchMotionBinaryContract.headerByteCount)), expectedPayload)
    }

    func testDualStreamSummariesFinalizeMetadataAsOneAssetSet() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = "00112233-4455-6677-8899-AABBCCDDEEFF"
        let deviceURL = directory.appendingPathComponent(
            WatchRecordingAssetNaming.deviceMotionFileName(sessionID: sessionID)
        )
        let rawURL = directory.appendingPathComponent(
            WatchRecordingAssetNaming.rawAccelerometerFileName(sessionID: sessionID)
        )
        let deviceWriter = try WatchMotionBinaryFileWriter(
            stream: .deviceMotion,
            fileURL: deviceURL,
            sessionID: sessionID
        )
        let rawWriter = try WatchMotionBinaryFileWriter(
            stream: .rawAccelerometer,
            fileURL: rawURL,
            sessionID: sessionID
        )
        try deviceWriter.append(deviceRecord(timestamp: 1))
        try rawWriter.append(rawRecord(timestamp: 1, x: 0))
        let deviceSummary = try deviceWriter.finalize(actualFrequencyHz: 200)
        let rawSummary = try rawWriter.finalize(actualFrequencyHz: 800)
        let metadata = WatchRecordingMetadata(
            sessionID: sessionID,
            plannedStartUnix: 100,
            actualWatchStartUnix: 100.005,
            createdUnix: 99,
            applicationPayloads: ["rating": "good"]
        ).finalized(deviceMotion: deviceSummary, rawAccelerometer: rawSummary)

        let decoded = try JSONDecoder().decode(
            WatchRecordingMetadata.self,
            from: JSONEncoder().encode(metadata)
        )

        XCTAssertEqual(decoded, metadata)
        XCTAssertEqual(decoded.deviceMotionFileName, deviceURL.lastPathComponent)
        XCTAssertEqual(decoded.rawAccelerometerFileName, rawURL.lastPathComponent)
        XCTAssertEqual(decoded.actualDeviceMotionFrequency, 200)
        XCTAssertEqual(decoded.actualRawAccelerometerFrequency, 800)
        XCTAssertEqual(decoded.deviceMotionSampleCount, 1)
        XCTAssertEqual(decoded.rawAccelerometerSampleCount, 1)
        XCTAssertEqual(decoded.applicationPayloads, ["rating": "good"])
    }

    func testPendingStoreGroupsBinaryPairAndMetadataUnderOneSession() throws {
        let sessionID = UUID().uuidString.lowercased()
        let directory = WatchPendingRecordingStore.recordingsDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = [
            directory.appendingPathComponent(WatchRecordingAssetNaming.deviceMotionFileName(sessionID: sessionID)),
            directory.appendingPathComponent(WatchRecordingAssetNaming.rawAccelerometerFileName(sessionID: sessionID)),
            directory.appendingPathComponent(WatchRecordingAssetNaming.metadataFileName(sessionID: sessionID)),
        ]
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(".\(url.lastPathComponent).synced")
                )
            }
        }
        for url in urls {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }

        let pending = try XCTUnwrap(
            WatchPendingRecordingStore.pendingSessions().first { $0.sessionID == sessionID }
        )
        XCTAssertEqual(Set(pending.fileURLs), Set(urls))

        WatchPendingRecordingStore.markFileSynced(urls[0])
        let retry = try XCTUnwrap(
            WatchPendingRecordingStore.pendingSessions().first { $0.sessionID == sessionID }
        )
        XCTAssertEqual(Set(retry.fileURLs), Set(urls.dropFirst()))
    }

    func testLiveTelemetryThrottlesPublishedSnapshots() throws {
        var telemetry = WatchLiveTelemetryBuffer(maximumPointCount: 3)

        XCTAssertNil(telemetry.snapshotIfDue(
            now: 0.05,
            sampleCount: 10,
            latestAccelMagnitude: 1,
            latestGyroMagnitude: 2
        ))

        let snapshot = try XCTUnwrap(telemetry.snapshotIfDue(
            now: 0.1,
            sampleCount: 20,
            latestAccelMagnitude: 3,
            latestGyroMagnitude: 4
        ))
        XCTAssertEqual(snapshot.sampleCount, 20)
        XCTAssertEqual(snapshot.latestAccelMagnitude, 3)
        XCTAssertEqual(snapshot.latestGyroMagnitude, 4)
        XCTAssertFalse(snapshot.includesGraph)
        XCTAssertTrue(snapshot.accelPoints.isEmpty)
        XCTAssertNil(telemetry.snapshotIfDue(
            now: 0.15,
            sampleCount: 30,
            latestAccelMagnitude: 5,
            latestGyroMagnitude: 6
        ))
    }

    func testLiveTelemetryDecimatesAndCapsGraphHistory() throws {
        var telemetry = WatchLiveTelemetryBuffer(maximumPointCount: 3)
        XCTAssertTrue(telemetry.setGraphEnabled(true))
        XCTAssertFalse(telemetry.setGraphEnabled(true))

        var accelPoints: [Double] = []
        var gyroPoints: [Double] = []
        for sample in 0..<40 where telemetry.shouldAppendGraphPoint() {
            accelPoints.append(Double(sample))
            gyroPoints.append(Double(sample * 10))
        }
        telemetry.appendGraphPoints(
            accelMagnitudes: accelPoints,
            gyroMagnitudes: gyroPoints
        )

        let snapshot = try XCTUnwrap(telemetry.snapshotIfDue(
            now: 1,
            sampleCount: 40,
            latestAccelMagnitude: 39,
            latestGyroMagnitude: 390
        ))
        XCTAssertTrue(snapshot.includesGraph)
        XCTAssertEqual(snapshot.accelPoints, [16, 24, 32])
        XCTAssertEqual(snapshot.gyroPoints, [160, 240, 320])
    }

    func testAssetNamingRequiresUUIDAcrossBothBinarySuffixesAndMetadata() {
        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        XCTAssertEqual(WatchRecordingAssetNaming.baseName(sessionID: sessionID), sessionID)
        XCTAssertEqual(
            RecordingPackageLayout.packageDirectoryName(sessionID: sessionID),
            "\(sessionID).recording"
        )
        XCTAssertEqual(
            WatchRecordingAssetNaming.sessionID(from: "\(sessionID).device-motion.bin"),
            sessionID
        )
        XCTAssertEqual(
            WatchRecordingAssetNaming.sessionID(from: "\(sessionID).raw-accelerometer.bin"),
            sessionID
        )
        XCTAssertEqual(
            WatchRecordingAssetNaming.sessionID(from: "\(sessionID).watch.json"),
            sessionID
        )
        XCTAssertEqual(
            WatchRecordingAssetNaming.sessionID(from: "recording_\(sessionID).device-motion.bin"),
            sessionID
        )
        XCTAssertNil(WatchRecordingAssetNaming.sessionID(from: "abc.device-motion.bin"))
        XCTAssertNil(WatchRecordingAssetNaming.sessionID(from: "abc.txt"))
    }

    func testCoreRecordingPackageDiscoversRequiredAssetsAndIgnoresHiddenFiles() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        let packageURL = RecordingPackageLayout.packageURL(in: rootURL, sessionID: sessionID)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for kind in RecordingPackageAssetKind.allCases where kind.isCoreAsset {
            let fileURL = RecordingPackageLayout.assetURL(kind, in: packageURL, sessionID: sessionID)
            XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
        }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: packageURL.appendingPathComponent(".DS_Store").path,
            contents: Data()
        ))

        let descriptor = try RecordingPackageDescriptor(
            packageURL: packageURL,
            expectedProfile: .core
        )

        XCTAssertEqual(descriptor.sessionID, sessionID)
        XCTAssertEqual(descriptor.profile, .core)
        XCTAssertEqual(descriptor.allAssetURLs.count, 3)
    }

    func testExtendedRecordingPackageRequiresPhoneMetadataWithVideo() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        let packageURL = RecordingPackageLayout.packageURL(in: rootURL, sessionID: sessionID)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for kind in RecordingPackageAssetKind.allCases where kind.isCoreAsset || kind == .video {
            let fileURL = RecordingPackageLayout.assetURL(kind, in: packageURL, sessionID: sessionID)
            XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
        }

        XCTAssertThrowsError(try RecordingPackageDescriptor(packageURL: packageURL)) {
            XCTAssertEqual($0 as? RecordingPackageError, .videoMetadataRequired)
        }

        let phoneMetadataURL = RecordingPackageLayout.assetURL(.phoneMetadata, in: packageURL, sessionID: sessionID)
        XCTAssertTrue(FileManager.default.createFile(atPath: phoneMetadataURL.path, contents: Data()))
        let descriptor = try RecordingPackageDescriptor(packageURL: packageURL, expectedProfile: .extended)
        XCTAssertEqual(
            descriptor.videoURL?.lastPathComponent,
            RecordingPackageLayout.assetFileName(.video, sessionID: sessionID)
        )
        XCTAssertEqual(
            descriptor.phoneMetadataURL?.lastPathComponent,
            RecordingPackageLayout.assetFileName(.phoneMetadata, sessionID: sessionID)
        )
    }

    private func rawRecord(timestamp: Int64, x: Double) -> WatchRawAccelerometerBinaryRecord {
        WatchRawAccelerometerBinaryRecord(
            timestampUnixMicroseconds: timestamp,
            rawAccelerationX: x,
            rawAccelerationY: 0,
            rawAccelerationZ: 1
        )
    }

    private func deviceRecord(timestamp: Int64) -> WatchDeviceMotionBinaryRecord {
        WatchDeviceMotionBinaryRecord(
            timestampUnixMicroseconds: timestamp,
            userAccelerationX: 0,
            userAccelerationY: 0,
            userAccelerationZ: 0,
            rotationRateX: 0,
            rotationRateY: 0,
            rotationRateZ: 0,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 1,
            quaternionW: 1,
            quaternionX: 0,
            quaternionY: 0,
            quaternionZ: 0
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchMotionRecordingKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
