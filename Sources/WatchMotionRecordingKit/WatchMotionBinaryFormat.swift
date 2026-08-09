import CryptoKit
import Foundation

/// Fixed sizes and format version shared by writers and readers.
///
/// Changing any value here changes the on-disk contract and requires a new format
/// version plus compatible readers in both consuming apps.
public enum WatchMotionBinaryContract {
    public static let headerByteCount = 64
    public static let formatVersion: UInt16 = 1
    public static let deviceMotionRecordByteCount = 60
    public static let rawAccelerometerRecordByteCount = 20
    public static let sessionIDByteCount = 16
}

/// Generates and parses the common filenames for one recording session.
public enum WatchRecordingAssetNaming {
    public static func baseName(sessionID: String) -> String {
        canonicalSessionID(sessionID)
    }

    public static func deviceMotionFileName(sessionID: String) -> String {
        baseName(sessionID: sessionID) + WatchMotionBinaryStream.deviceMotion.fileSuffix
    }

    public static func rawAccelerometerFileName(sessionID: String) -> String {
        baseName(sessionID: sessionID) + WatchMotionBinaryStream.rawAccelerometer.fileSuffix
    }

    public static func metadataFileName(sessionID: String) -> String {
        baseName(sessionID: sessionID) + ".watch.json"
    }

    public static func audioFileName(sessionID: String) -> String {
        baseName(sessionID: sessionID) + ".m4a"
    }

    public static func videoFileName(sessionID: String) -> String {
        baseName(sessionID: sessionID) + ".mov"
    }

    public static func phoneMetadataFileName(sessionID: String) -> String {
        baseName(sessionID: sessionID) + ".phone.json"
    }

    public static func sessionID(from fileName: String) -> String? {
        let suffixes = [
            WatchMotionBinaryStream.deviceMotion.fileSuffix,
            WatchMotionBinaryStream.rawAccelerometer.fileSuffix,
            ".watch.json",
            ".phone.json",
            ".m4a",
            ".mov",
        ]
        guard let suffix = suffixes.first(where: fileName.hasSuffix) else { return nil }
        let prefix = fileName.hasPrefix("recording_") ? "recording_" : ""
        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let candidate = String(fileName[start..<end])
        guard let identifier = UUID(uuidString: candidate) else { return nil }
        return identifier.uuidString.lowercased()
    }

    private static func canonicalSessionID(_ sessionID: String) -> String {
        UUID(uuidString: sessionID)?.uuidString.lowercased() ?? sessionID
    }
}

/// The two independently timestamped sensor streams stored by each session.
public enum WatchMotionBinaryStream: String, Codable, CaseIterable, Sendable {
    case deviceMotion
    case rawAccelerometer

    public var magic: Data {
        switch self {
        case .deviceMotion:
            return Data("WMRDM001".utf8)
        case .rawAccelerometer:
            return Data("WMRRA001".utf8)
        }
    }

    public var recordSize: UInt16 {
        switch self {
        case .deviceMotion:
            return UInt16(WatchMotionBinaryContract.deviceMotionRecordByteCount)
        case .rawAccelerometer:
            return UInt16(WatchMotionBinaryContract.rawAccelerometerRecordByteCount)
        }
    }

    public var componentCount: UInt64 {
        switch self {
        case .deviceMotion:
            return 13
        case .rawAccelerometer:
            return 3
        }
    }

    public var nominalFrequencyHz: UInt16 {
        switch self {
        case .deviceMotion:
            return 200
        case .rawAccelerometer:
            return 800
        }
    }

    public var fileSuffix: String {
        switch self {
        case .deviceMotion:
            return ".device-motion.bin"
        case .rawAccelerometer:
            return ".raw-accelerometer.bin"
        }
    }
}

/// Validation and lifecycle errors for the versioned binary format.
public enum WatchMotionBinaryError: Error, Equatable, LocalizedError {
    case invalidHeaderLength(Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidRecordSize(expected: UInt16, actual: UInt16)
    case invalidSessionID
    case sessionMismatch(expected: String, actual: String)
    case invalidFrequency(UInt16)
    case invalidFileLength(Int)
    case sampleCountMismatch(expected: UInt64, actual: UInt64)
    case invalidRecordLength(expected: Int, actual: Int)
    case nonFiniteValue
    case nonMonotonicTimestamp(previous: Int64, next: Int64)
    case writerFinalized

    public var errorDescription: String? {
        switch self {
        case .invalidHeaderLength(let length):
            return "Invalid motion header length: \(length)"
        case .invalidMagic:
            return "Unrecognized motion binary magic"
        case .unsupportedVersion(let version):
            return "Unsupported motion binary version: \(version)"
        case .invalidRecordSize(let expected, let actual):
            return "Invalid record size \(actual); expected \(expected)"
        case .invalidSessionID:
            return "Invalid binary session identifier"
        case .sessionMismatch(let expected, let actual):
            return "Binary session identifier \(actual) does not match \(expected)"
        case .invalidFrequency(let frequency):
            return "Invalid motion frequency: \(frequency) Hz"
        case .invalidFileLength(let length):
            return "Invalid motion binary file length: \(length)"
        case .sampleCountMismatch(let expected, let actual):
            return "Binary sample count \(actual) does not match header count \(expected)"
        case .invalidRecordLength(let expected, let actual):
            return "Invalid motion record length \(actual); expected \(expected)"
        case .nonFiniteValue:
            return "Motion value is not finite"
        case .nonMonotonicTimestamp(let previous, let next):
            return "Motion timestamp regressed from \(previous) to \(next)"
        case .writerFinalized:
            return "Motion binary writer is already finalized"
        }
    }
}

/// The fixed 64-byte prefix at the beginning of every motion binary file.
///
/// It identifies the stream and format, ties the file to a session UUID, and
/// records the final frequency and sample count. Exact offsets are documented in
/// the package README.
public struct WatchMotionBinaryHeader: Sendable, Equatable {
    public let stream: WatchMotionBinaryStream
    public let formatVersion: UInt16
    public let recordSize: UInt16
    public let sampleCount: UInt64
    public let sessionID: String
    public let actualFrequencyHz: UInt16

    public init(
        stream: WatchMotionBinaryStream,
        sampleCount: UInt64,
        sessionID: String,
        actualFrequencyHz: UInt16,
        formatVersion: UInt16 = WatchMotionBinaryContract.formatVersion
    ) {
        self.stream = stream
        self.formatVersion = formatVersion
        self.recordSize = stream.recordSize
        self.sampleCount = sampleCount
        self.sessionID = Self.canonicalSessionID(sessionID)
        self.actualFrequencyHz = actualFrequencyHz
    }

    public func encoded() throws -> Data {
        try validateContract(expectedStream: stream, expectedSessionID: sessionID)
        let sessionBytes = try encodedSessionIdentifier()

        var data = Data(capacity: WatchMotionBinaryContract.headerByteCount)
        data.append(stream.magic)
        data.appendLittleEndian(formatVersion)
        data.appendLittleEndian(recordSize)
        data.appendLittleEndian(sampleCount)
        data.append(sessionBytes)
        data.appendLittleEndian(actualFrequencyHz)
        data.append(Data(count: 26))

        guard data.count == WatchMotionBinaryContract.headerByteCount else {
            throw WatchMotionBinaryError.invalidHeaderLength(data.count)
        }
        return data
    }

    public static func decode(
        from data: Data,
        expectedStream: WatchMotionBinaryStream? = nil,
        expectedSessionID: String? = nil
    ) throws -> Self {
        guard data.count >= WatchMotionBinaryContract.headerByteCount else {
            throw WatchMotionBinaryError.invalidHeaderLength(data.count)
        }

        var reader = LittleEndianDataReader(data: data.prefix(WatchMotionBinaryContract.headerByteCount))
        let magic = try reader.readData(count: 8)
        guard let stream = WatchMotionBinaryStream.allCases.first(where: { $0.magic == magic }) else {
            throw WatchMotionBinaryError.invalidMagic
        }
        let formatVersion = try reader.readUInt16()
        let recordSize = try reader.readUInt16()
        let sampleCount = try reader.readUInt64()
        let sessionData = try reader.readData(count: WatchMotionBinaryContract.sessionIDByteCount)
        let actualFrequencyHz = try reader.readUInt16()
        let _ = try reader.readData(count: 26) // reserved

        let sessionID = try decodeSessionIdentifier(sessionData, formatVersion: formatVersion)

        let header = Self(
            stream: stream,
            formatVersion: formatVersion,
            recordSize: recordSize,
            sampleCount: sampleCount,
            sessionID: sessionID,
            actualFrequencyHz: actualFrequencyHz
        )
        try header.validateContract(expectedStream: expectedStream, expectedSessionID: expectedSessionID)
        return header
    }

    @discardableResult
    public func validateFileByteCount(_ byteCount: Int) throws -> UInt64 {
        guard byteCount >= WatchMotionBinaryContract.headerByteCount else {
            throw WatchMotionBinaryError.invalidFileLength(byteCount)
        }
        let payloadByteCount = byteCount - WatchMotionBinaryContract.headerByteCount
        guard payloadByteCount.isMultiple(of: Int(recordSize)) else {
            throw WatchMotionBinaryError.invalidFileLength(byteCount)
        }
        let derivedCount = UInt64(payloadByteCount / Int(recordSize))
        guard derivedCount == sampleCount else {
            throw WatchMotionBinaryError.sampleCountMismatch(expected: sampleCount, actual: derivedCount)
        }
        return derivedCount
    }

    private init(
        stream: WatchMotionBinaryStream,
        formatVersion: UInt16,
        recordSize: UInt16,
        sampleCount: UInt64,
        sessionID: String,
        actualFrequencyHz: UInt16
    ) {
        self.stream = stream
        self.formatVersion = formatVersion
        self.recordSize = recordSize
        self.sampleCount = sampleCount
        self.sessionID = sessionID
        self.actualFrequencyHz = actualFrequencyHz
    }

    private func validateContract(
        expectedStream: WatchMotionBinaryStream?,
        expectedSessionID: String?
    ) throws {
        if let expectedStream, stream != expectedStream {
            throw WatchMotionBinaryError.invalidMagic
        }
        guard formatVersion == WatchMotionBinaryContract.formatVersion else {
            throw WatchMotionBinaryError.unsupportedVersion(formatVersion)
        }
        guard recordSize == stream.recordSize else {
            throw WatchMotionBinaryError.invalidRecordSize(expected: stream.recordSize, actual: recordSize)
        }
        guard actualFrequencyHz > 0 else {
            throw WatchMotionBinaryError.invalidFrequency(actualFrequencyHz)
        }
        _ = try encodedSessionIdentifier()
        if let expectedSessionID, !sessionIDsMatch(sessionID, expectedSessionID) {
            throw WatchMotionBinaryError.sessionMismatch(expected: expectedSessionID, actual: sessionID)
        }
    }

    private func encodedSessionIdentifier() throws -> Data {
        guard let identifier = UUID(uuidString: sessionID) else {
            throw WatchMotionBinaryError.invalidSessionID
        }
        let bytes = identifier.uuid
        let identifierBytes = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7, bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15]
        guard Self.isRFC4122UUID(identifierBytes) else { throw WatchMotionBinaryError.invalidSessionID }
        return Data(identifierBytes)
    }

    private static func decodeSessionIdentifier(_ data: Data, formatVersion: UInt16) throws -> String {
        let bytes = Array(data)
        guard formatVersion == WatchMotionBinaryContract.formatVersion else { throw WatchMotionBinaryError.unsupportedVersion(formatVersion) }
        guard Self.isRFC4122UUID(bytes) else {
            throw WatchMotionBinaryError.invalidSessionID
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }

    private static func isRFC4122UUID(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == WatchMotionBinaryContract.sessionIDByteCount else { return false }
        let version = bytes[6] >> 4
        return (UInt8(1)...UInt8(8)).contains(version) && (bytes[8] & 0b1100_0000) == 0b1000_0000
    }

    private static func canonicalSessionID(_ sessionID: String) -> String {
        if let identifier = UUID(uuidString: sessionID) {
            return identifier.uuidString.lowercased()
        }
        return sessionID
    }

    private func sessionIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsUUID = UUID(uuidString: lhs), let rhsUUID = UUID(uuidString: rhs) {
            return lhsUUID == rhsUUID
        }
        return lhs == rhs
    }
}

/// Validated little-endian bytes for one sensor record.
public struct WatchMotionEncodedRecord: Sendable, Equatable {
    public let data: Data
}

/// One 200 Hz device-motion sample with its own Unix-microsecond timestamp.
///
/// Values are exposed as `Double` to callers and encoded as `Float32` on disk.
public struct WatchDeviceMotionBinaryRecord: Sendable, Equatable {
    public let timestampUnixMicroseconds: Int64
    public let userAccelerationX: Double
    public let userAccelerationY: Double
    public let userAccelerationZ: Double
    public let rotationRateX: Double
    public let rotationRateY: Double
    public let rotationRateZ: Double
    public let gravityX: Double
    public let gravityY: Double
    public let gravityZ: Double
    public let quaternionW: Double
    public let quaternionX: Double
    public let quaternionY: Double
    public let quaternionZ: Double

    public init(
        timestampUnixMicroseconds: Int64,
        userAccelerationX: Double,
        userAccelerationY: Double,
        userAccelerationZ: Double,
        rotationRateX: Double,
        rotationRateY: Double,
        rotationRateZ: Double,
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double,
        quaternionW: Double,
        quaternionX: Double,
        quaternionY: Double,
        quaternionZ: Double
    ) {
        self.timestampUnixMicroseconds = timestampUnixMicroseconds
        self.userAccelerationX = userAccelerationX
        self.userAccelerationY = userAccelerationY
        self.userAccelerationZ = userAccelerationZ
        self.rotationRateX = rotationRateX
        self.rotationRateY = rotationRateY
        self.rotationRateZ = rotationRateZ
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.quaternionW = quaternionW
        self.quaternionX = quaternionX
        self.quaternionY = quaternionY
        self.quaternionZ = quaternionZ
    }

    public func encoded() throws -> WatchMotionEncodedRecord {
        var data = Data(capacity: WatchMotionBinaryContract.deviceMotionRecordByteCount)
        try appendEncoded(to: &data)
        return WatchMotionEncodedRecord(data: data)
    }

    fileprivate func appendEncoded(to data: inout Data) throws {
        guard userAccelerationX.isFinite,
              userAccelerationY.isFinite,
              userAccelerationZ.isFinite,
              rotationRateX.isFinite,
              rotationRateY.isFinite,
              rotationRateZ.isFinite,
              gravityX.isFinite,
              gravityY.isFinite,
              gravityZ.isFinite,
              quaternionW.isFinite,
              quaternionX.isFinite,
              quaternionY.isFinite,
              quaternionZ.isFinite
        else {
            throw WatchMotionBinaryError.nonFiniteValue
        }

        data.appendLittleEndian(UInt64(bitPattern: timestampUnixMicroseconds))
        data.appendLittleEndian(Float32(userAccelerationX))
        data.appendLittleEndian(Float32(userAccelerationY))
        data.appendLittleEndian(Float32(userAccelerationZ))
        data.appendLittleEndian(Float32(rotationRateX))
        data.appendLittleEndian(Float32(rotationRateY))
        data.appendLittleEndian(Float32(rotationRateZ))
        data.appendLittleEndian(Float32(gravityX))
        data.appendLittleEndian(Float32(gravityY))
        data.appendLittleEndian(Float32(gravityZ))
        data.appendLittleEndian(Float32(quaternionW))
        data.appendLittleEndian(Float32(quaternionX))
        data.appendLittleEndian(Float32(quaternionY))
        data.appendLittleEndian(Float32(quaternionZ))
    }

    public static func decode(from data: Data) throws -> Self {
        guard data.count == WatchMotionBinaryContract.deviceMotionRecordByteCount else {
            throw WatchMotionBinaryError.invalidRecordLength(
                expected: WatchMotionBinaryContract.deviceMotionRecordByteCount,
                actual: data.count
            )
        }
        var reader = LittleEndianDataReader(data: data)
        let timestamp = Int64(bitPattern: try reader.readUInt64())
        var values: [Double] = []
        values.reserveCapacity(13)
        for _ in 0..<13 {
            values.append(Double(Float32(bitPattern: try reader.readUInt32())))
        }
        return Self(
            timestampUnixMicroseconds: timestamp,
            userAccelerationX: values[0], userAccelerationY: values[1], userAccelerationZ: values[2],
            rotationRateX: values[3], rotationRateY: values[4], rotationRateZ: values[5],
            gravityX: values[6], gravityY: values[7], gravityZ: values[8],
            quaternionW: values[9], quaternionX: values[10], quaternionY: values[11], quaternionZ: values[12]
        )
    }
}

/// One native 800 Hz acceleration sample with its own Unix-microsecond timestamp.
public struct WatchRawAccelerometerBinaryRecord: Sendable, Equatable {
    public let timestampUnixMicroseconds: Int64
    public let rawAccelerationX: Double
    public let rawAccelerationY: Double
    public let rawAccelerationZ: Double

    public init(
        timestampUnixMicroseconds: Int64,
        rawAccelerationX: Double,
        rawAccelerationY: Double,
        rawAccelerationZ: Double
    ) {
        self.timestampUnixMicroseconds = timestampUnixMicroseconds
        self.rawAccelerationX = rawAccelerationX
        self.rawAccelerationY = rawAccelerationY
        self.rawAccelerationZ = rawAccelerationZ
    }

    public func encoded() throws -> WatchMotionEncodedRecord {
        var data = Data(capacity: WatchMotionBinaryContract.rawAccelerometerRecordByteCount)
        try appendEncoded(to: &data)
        return WatchMotionEncodedRecord(data: data)
    }

    fileprivate func appendEncoded(to data: inout Data) throws {
        guard rawAccelerationX.isFinite,
              rawAccelerationY.isFinite,
              rawAccelerationZ.isFinite
        else {
            throw WatchMotionBinaryError.nonFiniteValue
        }

        data.appendLittleEndian(UInt64(bitPattern: timestampUnixMicroseconds))
        data.appendLittleEndian(Float32(rawAccelerationX))
        data.appendLittleEndian(Float32(rawAccelerationY))
        data.appendLittleEndian(Float32(rawAccelerationZ))
    }

    public static func decode(from data: Data) throws -> Self {
        guard data.count == WatchMotionBinaryContract.rawAccelerometerRecordByteCount else {
            throw WatchMotionBinaryError.invalidRecordLength(
                expected: WatchMotionBinaryContract.rawAccelerometerRecordByteCount,
                actual: data.count
            )
        }
        var reader = LittleEndianDataReader(data: data)
        let timestamp = Int64(bitPattern: try reader.readUInt64())
        let x = Double(Float32(bitPattern: try reader.readUInt32()))
        let y = Double(Float32(bitPattern: try reader.readUInt32()))
        let z = Double(Float32(bitPattern: try reader.readUInt32()))
        return Self(
            timestampUnixMicroseconds: timestamp,
            rawAccelerationX: x,
            rawAccelerationY: y,
            rawAccelerationZ: z
        )
    }
}

/// Final integrity and sample information copied into the Watch metadata sidecar.
public struct WatchMotionBinaryFileSummary: Sendable, Equatable {
    public let stream: WatchMotionBinaryStream
    public let fileName: String
    public let byteCount: UInt64
    public let sha256: String
    public let formatVersion: UInt16
    public let sampleCount: UInt64
    public let actualFrequencyHz: UInt16
}

/// Writes one ordered sensor stream and finalizes its binary header and hash.
///
/// Initialization writes a placeholder header with zero samples. Appends validate
/// monotonic timestamps. `finalize(actualFrequencyHz:)` rewrites the header with
/// the true count, closes the file, validates its length, and calculates SHA-256.
public final class WatchMotionBinaryFileWriter {
    public let stream: WatchMotionBinaryStream
    public let fileURL: URL
    public let sessionID: String
    public private(set) var sampleCount: UInt64 = 0

    private var handle: FileHandle?
    private var lastTimestamp: Int64?

    public init(
        stream: WatchMotionBinaryStream,
        fileURL: URL,
        sessionID: String,
        initialFrequencyHz: UInt16? = nil
    ) throws {
        self.stream = stream
        self.fileURL = fileURL
        self.sessionID = sessionID

        guard UUID(uuidString: sessionID) != nil else {
            throw WatchMotionBinaryError.invalidSessionID
        }

        let header = WatchMotionBinaryHeader(
            stream: stream,
            sampleCount: 0,
            sessionID: sessionID,
            actualFrequencyHz: initialFrequencyHz ?? stream.nominalFrequencyHz
        )
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        guard fileManager.createFile(atPath: fileURL.path, contents: try header.encoded()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        try handle?.seekToEnd()
    }

    deinit {
        try? handle?.close()
    }

    /// Appends one device-motion record. Batch append is preferred during capture.
    public func append(_ record: WatchDeviceMotionBinaryRecord) throws {
        guard stream == .deviceMotion else { throw WatchMotionBinaryError.invalidMagic }
        try append(
            timestamp: record.timestampUnixMicroseconds,
            encoded: record.encoded()
        )
    }

    /// Appends one raw-acceleration record. Batch append is preferred during capture.
    public func append(_ record: WatchRawAccelerometerBinaryRecord) throws {
        guard stream == .rawAccelerometer else { throw WatchMotionBinaryError.invalidMagic }
        try append(
            timestamp: record.timestampUnixMicroseconds,
            encoded: record.encoded()
        )
    }

    /// Encodes and writes a device-motion batch as one contiguous payload.
    public func append(contentsOf records: [WatchDeviceMotionBinaryRecord]) throws {
        guard stream == .deviceMotion else { throw WatchMotionBinaryError.invalidMagic }
        guard !records.isEmpty else { return }

        var payload = Data(capacity: records.count * WatchMotionBinaryContract.deviceMotionRecordByteCount)
        var previousTimestamp = lastTimestamp
        for record in records {
            try validateTimestamp(record.timestampUnixMicroseconds, after: previousTimestamp)
            try record.appendEncoded(to: &payload)
            previousTimestamp = record.timestampUnixMicroseconds
        }
        try appendEncodedBatch(
            payload,
            sampleCount: records.count,
            lastTimestamp: previousTimestamp
        )
    }

    /// Encodes and writes a raw-acceleration batch as one contiguous payload.
    public func append(contentsOf records: [WatchRawAccelerometerBinaryRecord]) throws {
        guard stream == .rawAccelerometer else { throw WatchMotionBinaryError.invalidMagic }
        guard !records.isEmpty else { return }

        var payload = Data(capacity: records.count * WatchMotionBinaryContract.rawAccelerometerRecordByteCount)
        var previousTimestamp = lastTimestamp
        for record in records {
            try validateTimestamp(record.timestampUnixMicroseconds, after: previousTimestamp)
            try record.appendEncoded(to: &payload)
            previousTimestamp = record.timestampUnixMicroseconds
        }
        try appendEncodedBatch(
            payload,
            sampleCount: records.count,
            lastTimestamp: previousTimestamp
        )
    }

    /// Requests that already-written bytes be synchronized to storage.
    public func synchronize() throws {
        guard let handle else { throw WatchMotionBinaryError.writerFinalized }
        try handle.synchronize()
    }

    /// Seals the file and returns metadata required to validate it after transfer.
    ///
    /// A finalized writer cannot accept more records.
    public func finalize(actualFrequencyHz: UInt16) throws -> WatchMotionBinaryFileSummary {
        guard let handle else { throw WatchMotionBinaryError.writerFinalized }
        let header = WatchMotionBinaryHeader(
            stream: stream,
            sampleCount: sampleCount,
            sessionID: sessionID,
            actualFrequencyHz: actualFrequencyHz
        )
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header.encoded())
        try handle.synchronize()
        try handle.close()
        self.handle = nil

        let byteCount = try WatchMotionFileIntegrity.byteCount(for: fileURL)
        try header.validateFileByteCount(Int(byteCount))
        return WatchMotionBinaryFileSummary(
            stream: stream,
            fileName: fileURL.lastPathComponent,
            byteCount: byteCount,
            sha256: try WatchMotionFileIntegrity.sha256Hex(for: fileURL),
            formatVersion: header.formatVersion,
            sampleCount: sampleCount,
            actualFrequencyHz: actualFrequencyHz
        )
    }

    private func append(timestamp: Int64, encoded: WatchMotionEncodedRecord) throws {
        guard handle != nil else { throw WatchMotionBinaryError.writerFinalized }
        try validateTimestamp(timestamp, after: lastTimestamp)
        try appendEncodedBatch(encoded.data, sampleCount: 1, lastTimestamp: timestamp)
    }

    private func appendEncodedBatch(
        _ payload: Data,
        sampleCount: Int,
        lastTimestamp: Int64?
    ) throws {
        guard let handle else { throw WatchMotionBinaryError.writerFinalized }
        try handle.write(contentsOf: payload)
        self.lastTimestamp = lastTimestamp
        self.sampleCount += UInt64(sampleCount)
    }

    private func validateTimestamp(_ timestamp: Int64, after previousTimestamp: Int64?) throws {
        if let previousTimestamp, timestamp < previousTimestamp {
            throw WatchMotionBinaryError.nonMonotonicTimestamp(previous: previousTimestamp, next: timestamp)
        }
    }
}

/// File-size and streaming SHA-256 helpers used during finalization and import.
public enum WatchMotionFileIntegrity {
    public static func byteCount(for url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return UInt64(size)
    }

    public static func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return sha256Hex(digest: hasher.finalize())
    }

    public static func sha256Hex(digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Converts projected Unix seconds into the integer timestamp stored on disk.
public enum WatchMotionTimestamp {
    public static func unixMicroseconds(from unixSeconds: Double) throws -> Int64 {
        guard unixSeconds.isFinite else {
            throw WatchMotionBinaryError.nonFiniteValue
        }
        let microseconds = (unixSeconds * 1_000_000).rounded()
        guard microseconds >= Double(Int64.min), microseconds <= Double(Int64.max) else {
            throw WatchMotionBinaryError.nonFiniteValue
        }
        return Int64(microseconds)
    }
}

private struct LittleEndianDataReader {
    let data: Data
    private(set) var offset = 0

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw WatchMotionBinaryError.invalidRecordLength(expected: offset + count, actual: data.count)
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUInt16() throws -> UInt16 {
        try readLittleEndian() as UInt16
    }

    mutating func readUInt32() throws -> UInt32 {
        try readLittleEndian() as UInt32
    }

    mutating func readUInt64() throws -> UInt64 {
        try readLittleEndian() as UInt64
    }

    private mutating func readLittleEndian<T: FixedWidthInteger>() throws -> T {
        let bytes = try readData(count: MemoryLayout<T>.size)
        return bytes.withUnsafeBytes { raw in
            T(littleEndian: raw.load(as: T.self))
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: Float32) {
        appendLittleEndian(value.bitPattern)
    }
}
