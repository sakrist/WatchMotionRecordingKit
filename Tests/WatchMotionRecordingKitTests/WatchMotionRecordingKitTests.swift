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
            actualFrequencyHz: 200,
            saturationCount: 13
        )

        let bytes = try header.encoded()

        XCTAssertEqual(bytes.count, 64)
        XCTAssertEqual(Data(bytes[0..<8]), Data("WMRDM001".utf8))
        XCTAssertEqual(Array(bytes[8..<12]), [1, 0, 34, 0])
        XCTAssertEqual(Array(bytes[12..<20]), [8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(Array(bytes[20..<36]), [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255])
        XCTAssertEqual(Array(bytes[36..<40]), [200, 0, 4, 0])
        XCTAssertEqual(readUInt32(bytes, at: 40), WatchMotionBinaryStream.deviceMotion.quantizationScales[0].bitPattern)
        XCTAssertEqual(readUInt32(bytes, at: 44), WatchMotionBinaryStream.deviceMotion.quantizationScales[1].bitPattern)
        XCTAssertEqual(readUInt32(bytes, at: 48), WatchMotionBinaryStream.deviceMotion.quantizationScales[2].bitPattern)
        XCTAssertEqual(readUInt32(bytes, at: 52), WatchMotionBinaryStream.deviceMotion.quantizationScales[3].bitPattern)
        XCTAssertEqual(Array(bytes[56..<64]), [13, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(try WatchMotionBinaryHeader.decode(from: bytes), header)
    }

    func testHeaderRejectsTextualSessionIdentity() {
        let header = WatchMotionBinaryHeader(
            stream: .deviceMotion,
            sampleCount: 0,
            sessionID: "20260722_143012",
            actualFrequencyHz: 200,
            saturationCount: 0
        )

        XCTAssertThrowsError(try header.encoded()) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .invalidSessionID)
        }
    }

    func testRawAccelerometerHeaderHasOneScaleAndZeroUnusedSlots() throws {
        let header = WatchMotionBinaryHeader(
            stream: .rawAccelerometer,
            sampleCount: 2,
            sessionID: "aabbccdd-eeff-4011-8233-445566778899",
            actualFrequencyHz: 800,
            saturationCount: 0
        )

        let bytes = try header.encoded()
        let decoded = try WatchMotionBinaryHeader.decode(from: bytes, expectedStream: .rawAccelerometer)

        XCTAssertEqual(Data(bytes[0..<8]), Data("WMRRA001".utf8))
        XCTAssertEqual(decoded.recordSize, 14)
        XCTAssertEqual(decoded.scaleCount, 1)
        XCTAssertEqual(decoded.quantizationScales[0].bitPattern, Float(256.0 / 32_767.0).bitPattern)
        XCTAssertEqual(decoded.quantizationScales.dropFirst(), [0, 0, 0])
    }

    func testDeviceMotionRecordHasExactFieldOrderAndLittleEndianBytes() throws {
        let scales = WatchMotionBinaryStream.deviceMotion.quantizationScales
        let record = WatchDeviceMotionBinaryRecord(
            timestampUnixMicroseconds: 0x0102_0304_0506_0708,
            userAccelerationX: Double(scales[0]) * 1,
            userAccelerationY: Double(scales[0]) * 2,
            userAccelerationZ: Double(scales[0]) * 3,
            rotationRateX: Double(scales[1]) * 4,
            rotationRateY: Double(scales[1]) * 5,
            rotationRateZ: Double(scales[1]) * 6,
            gravityX: Double(scales[2]) * 7,
            gravityY: Double(scales[2]) * 8,
            gravityZ: Double(scales[2]) * 9,
            quaternionW: Double(scales[3]) * 10,
            quaternionX: Double(scales[3]) * 11,
            quaternionY: Double(scales[3]) * 12,
            quaternionZ: Double(scales[3]) * 13
        )

        let encoded = try record.encoded()

        XCTAssertEqual(encoded.data.count, 34)
        XCTAssertEqual(Array(encoded.data[0..<8]), [8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(
            Array(encoded.data[8..<34]),
            (1...13).flatMap { [UInt8($0), 0] }
        )
        XCTAssertEqual(encoded.saturationCount, 0)
    }

    func testRawAccelerometerRecordRoundTripsWithinHalfScale() throws {
        let scale = WatchMotionBinaryStream.rawAccelerometer.quantizationScales[0]
        let source = WatchRawAccelerometerBinaryRecord(
            timestampUnixMicroseconds: 1_700_000_000_123_456,
            rawAccelerationX: -19.125,
            rawAccelerationY: 0.001,
            rawAccelerationZ: 42.75
        )

        let decoded = try WatchRawAccelerometerBinaryRecord.decode(from: source.encoded().data)

        XCTAssertEqual(decoded.timestampUnixMicroseconds, source.timestampUnixMicroseconds)
        XCTAssertEqual(decoded.rawAccelerationX, source.rawAccelerationX, accuracy: Double(scale) / 2)
        XCTAssertEqual(decoded.rawAccelerationY, source.rawAccelerationY, accuracy: Double(scale) / 2)
        XCTAssertEqual(decoded.rawAccelerationZ, source.rawAccelerationZ, accuracy: Double(scale) / 2)
    }

    func testQuantizationClampsSymmetricallyAndNeverEmitsReservedValue() throws {
        let scale = WatchMotionBinaryStream.rawAccelerometer.quantizationScales[0]

        let positive = try WatchMotionQuantizer.quantize(1_000, scale: scale)
        let negative = try WatchMotionQuantizer.quantize(-1_000, scale: scale)

        XCTAssertEqual(positive, WatchMotionQuantizedValue(value: 32_767, saturated: true))
        XCTAssertEqual(negative, WatchMotionQuantizedValue(value: -32_767, saturated: true))
        XCTAssertNotEqual(negative.value, .min)
    }

    func testNonFiniteValuesAreRejected() {
        let scale = WatchMotionBinaryStream.deviceMotion.quantizationScales[0]

        XCTAssertThrowsError(try WatchMotionQuantizer.quantize(.nan, scale: scale)) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .nonFiniteValue)
        }
        XCTAssertThrowsError(try WatchMotionQuantizer.quantize(.infinity, scale: scale)) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .nonFiniteValue)
        }
    }

    func testReservedInt16MinimumIsRejectedDuringDecode() {
        var bytes = Data(repeating: 0, count: WatchMotionBinaryContract.rawAccelerometerRecordByteCount)
        bytes[8] = 0
        bytes[9] = 0x80

        XCTAssertThrowsError(try WatchRawAccelerometerBinaryRecord.decode(from: bytes)) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .reservedQuantizedValue)
        }
    }

    func testHeaderRejectsUnsupportedVersionAndMismatchedSession() throws {
        let header = WatchMotionBinaryHeader(
            stream: .deviceMotion,
            sampleCount: 0,
            sessionID: "00112233-4455-6677-8899-AABBCCDDEEFF",
            actualFrequencyHz: 200,
            saturationCount: 0
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
            actualFrequencyHz: 200,
            saturationCount: 0
        )

        XCTAssertThrowsError(try header.validateFileByteCount(64 + 34 + 1)) {
            XCTAssertEqual($0 as? WatchMotionBinaryError, .invalidFileLength(99))
        }
        XCTAssertThrowsError(try header.validateFileByteCount(64 + 34)) {
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
        let url = directory.appendingPathComponent("recording_\(sessionID).raw-accelerometer.bin")
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
        XCTAssertEqual(summary.saturationCount, 1)
        XCTAssertEqual(summary.byteCount, UInt64(64 + (2 * 14)))
        XCTAssertEqual(summary.sha256, try WatchMotionFileIntegrity.sha256Hex(for: url))
        XCTAssertEqual(header.sampleCount, 2)
        XCTAssertEqual(header.saturationCount, 1)
        XCTAssertEqual(header.formatVersion, WatchMotionBinaryContract.formatVersion)
        XCTAssertEqual(header.sessionID, sessionID.lowercased())
        XCTAssertEqual(try header.validateFileByteCount(data.count), 2)
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

    func testAssetNamingRequiresUUIDAcrossBothBinarySuffixesAndMetadata() {
        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        XCTAssertEqual(
            WatchRecordingAssetNaming.sessionID(from: "recording_\(sessionID).device-motion.bin"),
            sessionID
        )
        XCTAssertEqual(
            WatchRecordingAssetNaming.sessionID(from: "recording_\(sessionID).raw-accelerometer.bin"),
            sessionID
        )
        XCTAssertEqual(
            WatchRecordingAssetNaming.sessionID(from: "recording_\(sessionID).watch.json"),
            sessionID
        )
        XCTAssertNil(WatchRecordingAssetNaming.sessionID(from: "recording_abc.device-motion.bin"))
        XCTAssertNil(WatchRecordingAssetNaming.sessionID(from: "recording_abc.txt"))
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

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(0) { result, pair in
            result | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
    }
}
