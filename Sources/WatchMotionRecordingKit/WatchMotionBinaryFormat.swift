import CryptoKit
import Foundation

public enum WatchMotionBinaryContract {
    public static let headerByteCount = 64
    public static let formatVersion: UInt16 = 1
    public static let deviceMotionRecordByteCount = 34
    public static let rawAccelerometerRecordByteCount = 14
    public static let sessionIDByteCount = 16
}

public enum WatchRecordingAssetNaming {
    public static func baseName(sessionID: String) -> String {
        "recording_\(canonicalSessionID(sessionID))"
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

    public static func sessionID(from fileName: String) -> String? {
        guard fileName.hasPrefix("recording_") else { return nil }
        let suffixes = [
            WatchMotionBinaryStream.deviceMotion.fileSuffix,
            WatchMotionBinaryStream.rawAccelerometer.fileSuffix,
            ".watch.json",
        ]
        guard let suffix = suffixes.first(where: fileName.hasSuffix) else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: "recording_".count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let sessionID = String(fileName[start..<end])
        return canonicalSessionID(sessionID)
    }

    private static func canonicalSessionID(_ sessionID: String) -> String {
        UUID(uuidString: sessionID)?.uuidString.lowercased() ?? sessionID
    }
}

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

    public var scaleCount: UInt16 {
        switch self {
        case .deviceMotion:
            return 4
        case .rawAccelerometer:
            return 1
        }
    }

    /// Four on-disk Float32 scale slots in physical units per stored count.
    public var quantizationScales: [Float] {
        switch self {
        case .deviceMotion:
            return [
                Float(64.0 / 32_767.0),
                Float(64.0 / 32_767.0),
                Float(1.0 / 32_767.0),
                Float(1.0 / 32_767.0),
            ]
        case .rawAccelerometer:
            return [
                Float(256.0 / 32_767.0),
                0,
                0,
                0,
            ]
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

public enum WatchMotionBinaryError: Error, Equatable, LocalizedError {
    case invalidHeaderLength(Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidRecordSize(expected: UInt16, actual: UInt16)
    case invalidSessionID
    case sessionMismatch(expected: String, actual: String)
    case invalidFrequency(UInt16)
    case invalidScaleCount(expected: UInt16, actual: UInt16)
    case invalidScale(index: Int)
    case invalidSaturationCount(UInt64)
    case invalidFileLength(Int)
    case sampleCountMismatch(expected: UInt64, actual: UInt64)
    case invalidRecordLength(expected: Int, actual: Int)
    case invalidQuantizationScale
    case nonFiniteValue
    case reservedQuantizedValue
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
        case .invalidScaleCount(let expected, let actual):
            return "Invalid quantization scale count \(actual); expected \(expected)"
        case .invalidScale(let index):
            return "Invalid quantization scale at index \(index)"
        case .invalidSaturationCount(let count):
            return "Invalid saturation count: \(count)"
        case .invalidFileLength(let length):
            return "Invalid motion binary file length: \(length)"
        case .sampleCountMismatch(let expected, let actual):
            return "Binary sample count \(actual) does not match header count \(expected)"
        case .invalidRecordLength(let expected, let actual):
            return "Invalid motion record length \(actual); expected \(expected)"
        case .invalidQuantizationScale:
            return "Quantization scale must be finite and positive"
        case .nonFiniteValue:
            return "Motion value is not finite"
        case .reservedQuantizedValue:
            return "Motion record contains the reserved Int16 minimum value"
        case .nonMonotonicTimestamp(let previous, let next):
            return "Motion timestamp regressed from \(previous) to \(next)"
        case .writerFinalized:
            return "Motion binary writer is already finalized"
        }
    }
}

public struct WatchMotionBinaryHeader: Sendable, Equatable {
    public let stream: WatchMotionBinaryStream
    public let formatVersion: UInt16
    public let recordSize: UInt16
    public let sampleCount: UInt64
    public let sessionID: String
    public let actualFrequencyHz: UInt16
    public let scaleCount: UInt16
    public let quantizationScales: [Float]
    public let saturationCount: UInt64

    public init(
        stream: WatchMotionBinaryStream,
        sampleCount: UInt64,
        sessionID: String,
        actualFrequencyHz: UInt16,
        saturationCount: UInt64,
        formatVersion: UInt16 = WatchMotionBinaryContract.formatVersion
    ) {
        self.stream = stream
        self.formatVersion = formatVersion
        self.recordSize = stream.recordSize
        self.sampleCount = sampleCount
        self.sessionID = Self.canonicalSessionID(sessionID)
        self.actualFrequencyHz = actualFrequencyHz
        self.scaleCount = stream.scaleCount
        self.quantizationScales = stream.quantizationScales
        self.saturationCount = saturationCount
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
        data.appendLittleEndian(scaleCount)
        for scale in quantizationScales {
            data.appendLittleEndian(scale.bitPattern)
        }
        data.appendLittleEndian(saturationCount)

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
        let scaleCount = try reader.readUInt16()
        let quantizationScales = try (0..<4).map { _ in Float(bitPattern: try reader.readUInt32()) }
        let saturationCount = try reader.readUInt64()

        let sessionID = try decodeSessionIdentifier(sessionData, formatVersion: formatVersion)

        let header = Self(
            stream: stream,
            formatVersion: formatVersion,
            recordSize: recordSize,
            sampleCount: sampleCount,
            sessionID: sessionID,
            actualFrequencyHz: actualFrequencyHz,
            scaleCount: scaleCount,
            quantizationScales: quantizationScales,
            saturationCount: saturationCount
        )
        try header.validateContract(expectedStream: expectedStream, expectedSessionID: expectedSessionID)
        return header
    }

    /// Validates the tail shape and header count, returning the file-derived record count.
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
        actualFrequencyHz: UInt16,
        scaleCount: UInt16,
        quantizationScales: [Float],
        saturationCount: UInt64
    ) {
        self.stream = stream
        self.formatVersion = formatVersion
        self.recordSize = recordSize
        self.sampleCount = sampleCount
        self.sessionID = sessionID
        self.actualFrequencyHz = actualFrequencyHz
        self.scaleCount = scaleCount
        self.quantizationScales = quantizationScales
        self.saturationCount = saturationCount
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
        guard scaleCount == stream.scaleCount else {
            throw WatchMotionBinaryError.invalidScaleCount(expected: stream.scaleCount, actual: scaleCount)
        }
        guard quantizationScales.count == 4 else {
            throw WatchMotionBinaryError.invalidScale(index: quantizationScales.count)
        }
        for (index, pair) in zip(quantizationScales, stream.quantizationScales).enumerated() {
            guard pair.0.bitPattern == pair.1.bitPattern else {
                throw WatchMotionBinaryError.invalidScale(index: index)
            }
        }
        let maximumSaturations = sampleCount.multipliedReportingOverflow(by: stream.componentCount)
        guard !maximumSaturations.overflow, saturationCount <= maximumSaturations.partialValue else {
            throw WatchMotionBinaryError.invalidSaturationCount(saturationCount)
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

public struct WatchMotionQuantizedValue: Sendable, Equatable {
    public let value: Int16
    public let saturated: Bool
}

public enum WatchMotionQuantizer {
    public static func quantize(_ value: Double, scale: Float) throws -> WatchMotionQuantizedValue {
        guard value.isFinite else {
            throw WatchMotionBinaryError.nonFiniteValue
        }
        guard scale.isFinite, scale > 0 else {
            throw WatchMotionBinaryError.invalidQuantizationScale
        }

        let rounded = (value / Double(scale)).rounded()
        let clamped = min(32_767.0, max(-32_767.0, rounded))
        return WatchMotionQuantizedValue(
            value: Int16(clamped),
            saturated: rounded != clamped
        )
    }

    public static func dequantize(_ value: Int16, scale: Float) throws -> Double {
        guard value != .min else {
            throw WatchMotionBinaryError.reservedQuantizedValue
        }
        guard scale.isFinite, scale > 0 else {
            throw WatchMotionBinaryError.invalidQuantizationScale
        }
        return Double(value) * Double(scale)
    }
}

public struct WatchMotionEncodedRecord: Sendable, Equatable {
    public let data: Data
    public let saturationCount: UInt64
}

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
        let scales = WatchMotionBinaryStream.deviceMotion.quantizationScales
        let groups: [([Double], Float)] = [
            ([userAccelerationX, userAccelerationY, userAccelerationZ], scales[0]),
            ([rotationRateX, rotationRateY, rotationRateZ], scales[1]),
            ([gravityX, gravityY, gravityZ], scales[2]),
            ([quaternionW, quaternionX, quaternionY, quaternionZ], scales[3]),
        ]

        var data = Data(capacity: WatchMotionBinaryContract.deviceMotionRecordByteCount)
        data.appendLittleEndian(UInt64(bitPattern: timestampUnixMicroseconds))
        var saturationCount: UInt64 = 0
        for (values, scale) in groups {
            for value in values {
                let quantized = try WatchMotionQuantizer.quantize(value, scale: scale)
                data.appendLittleEndian(UInt16(bitPattern: quantized.value))
                saturationCount += quantized.saturated ? 1 : 0
            }
        }
        return WatchMotionEncodedRecord(data: data, saturationCount: saturationCount)
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
        let scales = WatchMotionBinaryStream.deviceMotion.quantizationScales
        var values: [Double] = []
        values.reserveCapacity(13)
        for scale in [scales[0], scales[0], scales[0],
                      scales[1], scales[1], scales[1],
                      scales[2], scales[2], scales[2],
                      scales[3], scales[3], scales[3], scales[3]] {
            let stored = Int16(bitPattern: try reader.readUInt16())
            values.append(try WatchMotionQuantizer.dequantize(stored, scale: scale))
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
        let scale = WatchMotionBinaryStream.rawAccelerometer.quantizationScales[0]
        var data = Data(capacity: WatchMotionBinaryContract.rawAccelerometerRecordByteCount)
        data.appendLittleEndian(UInt64(bitPattern: timestampUnixMicroseconds))
        var saturationCount: UInt64 = 0
        for value in [rawAccelerationX, rawAccelerationY, rawAccelerationZ] {
            let quantized = try WatchMotionQuantizer.quantize(value, scale: scale)
            data.appendLittleEndian(UInt16(bitPattern: quantized.value))
            saturationCount += quantized.saturated ? 1 : 0
        }
        return WatchMotionEncodedRecord(data: data, saturationCount: saturationCount)
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
        let scale = WatchMotionBinaryStream.rawAccelerometer.quantizationScales[0]
        let x = try WatchMotionQuantizer.dequantize(Int16(bitPattern: reader.readUInt16()), scale: scale)
        let y = try WatchMotionQuantizer.dequantize(Int16(bitPattern: reader.readUInt16()), scale: scale)
        let z = try WatchMotionQuantizer.dequantize(Int16(bitPattern: reader.readUInt16()), scale: scale)
        return Self(
            timestampUnixMicroseconds: timestamp,
            rawAccelerationX: x,
            rawAccelerationY: y,
            rawAccelerationZ: z
        )
    }
}

public struct WatchMotionBinaryFileSummary: Sendable, Equatable {
    public let stream: WatchMotionBinaryStream
    public let fileName: String
    public let byteCount: UInt64
    public let sha256: String
    public let formatVersion: UInt16
    public let sampleCount: UInt64
    public let saturationCount: UInt64
    public let actualFrequencyHz: UInt16
}

public final class WatchMotionBinaryFileWriter {
    public let stream: WatchMotionBinaryStream
    public let fileURL: URL
    public let sessionID: String
    public private(set) var sampleCount: UInt64 = 0
    public private(set) var saturationCount: UInt64 = 0

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
            actualFrequencyHz: initialFrequencyHz ?? stream.nominalFrequencyHz,
            saturationCount: 0,
            formatVersion: WatchMotionBinaryContract.formatVersion
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

    public func append(_ record: WatchDeviceMotionBinaryRecord) throws {
        guard stream == .deviceMotion else { throw WatchMotionBinaryError.invalidMagic }
        try append(timestamp: record.timestampUnixMicroseconds, encoded: record.encoded())
    }

    public func append(_ record: WatchRawAccelerometerBinaryRecord) throws {
        guard stream == .rawAccelerometer else { throw WatchMotionBinaryError.invalidMagic }
        try append(timestamp: record.timestampUnixMicroseconds, encoded: record.encoded())
    }

    public func synchronize() throws {
        guard let handle else { throw WatchMotionBinaryError.writerFinalized }
        try handle.synchronize()
    }

    public func finalize(actualFrequencyHz: UInt16) throws -> WatchMotionBinaryFileSummary {
        guard let handle else { throw WatchMotionBinaryError.writerFinalized }
        let header = WatchMotionBinaryHeader(
            stream: stream,
            sampleCount: sampleCount,
            sessionID: sessionID,
            actualFrequencyHz: actualFrequencyHz,
            saturationCount: saturationCount,
            formatVersion: WatchMotionBinaryContract.formatVersion
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
            saturationCount: saturationCount,
            actualFrequencyHz: actualFrequencyHz
        )
    }

    private func append(timestamp: Int64, encoded: WatchMotionEncodedRecord) throws {
        guard let handle else { throw WatchMotionBinaryError.writerFinalized }
        if let lastTimestamp, timestamp < lastTimestamp {
            throw WatchMotionBinaryError.nonMonotonicTimestamp(previous: lastTimestamp, next: timestamp)
        }
        try handle.write(contentsOf: encoded.data)
        lastTimestamp = timestamp
        sampleCount += 1
        saturationCount += encoded.saturationCount
    }
}

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
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

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
        let bytes = try readData(count: 2)
        return UInt16(bytes[bytes.startIndex])
            | (UInt16(bytes[bytes.index(after: bytes.startIndex)]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.enumerated().reduce(0) { result, pair in
            result | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.enumerated().reduce(0) { result, pair in
            result | (UInt64(pair.element) << UInt64(pair.offset * 8))
        }
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}
