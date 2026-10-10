/// The checksum envelope around an atomically written file.
///
///     offset  size  field
///          0     4  magic "STAF"
///          4     1  version (1)
///          5     3  reserved, zero
///          8     8  payload length, little-endian
///         16     4  CRC-32C of bytes 4..<16 followed by the payload, little-endian
///         20     n  payload
///
/// The checksum covers the length too, so a flipped bit in the header is as
/// visible as one in the payload. The file must be exactly `20 + length`
/// bytes: a file that is longer than its envelope says, or shorter, is
/// corrupt, never "mostly fine". An empty file is corrupt, not an empty
/// payload — that is what a rename that outran its data looks like.
enum Envelope {
    static let headerSize = 20
    static let magic: [UInt8] = [0x53, 0x54, 0x41, 0x46]
    static let version: UInt8 = 1

    enum Failure: Error, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case badMagic
        case unsupportedVersion(UInt8)
        case lengthMismatch(declared: UInt64, actual: Int)
        case checksumMismatch

        var description: String {
            switch self {
            case .tooShort(let count): "only \(count) bytes, shorter than the \(headerSize)-byte header"
            case .badMagic: "bad magic"
            case .unsupportedVersion(let version): "unsupported envelope version \(version)"
            case .lengthMismatch(let declared, let actual): "header declares \(declared) payload bytes, file holds \(actual)"
            case .checksumMismatch: "checksum mismatch"
            }
        }
    }

    static func seal(_ payload: [UInt8]) -> [UInt8] {
        var header: [UInt8] = [version, 0, 0, 0]
        header.append(contentsOf: littleEndian(UInt64(payload.count)))
        var crc = CRC32C.Running()
        crc.update(header)
        crc.update(payload)
        var file = magic
        file.append(contentsOf: header)
        file.append(contentsOf: littleEndian(crc.value))
        file.append(contentsOf: payload)
        return file
    }

    static func open(_ file: [UInt8]) -> Result<[UInt8], Failure> {
        guard file.count >= headerSize else { return .failure(.tooShort(file.count)) }
        guard Array(file[0..<4]) == magic else { return .failure(.badMagic) }
        guard file[4] == version else { return .failure(.unsupportedVersion(file[4])) }
        let declared: UInt64 = readLittleEndian(file, at: 8)
        guard declared == UInt64(file.count - headerSize) else {
            return .failure(.lengthMismatch(declared: declared, actual: file.count - headerSize))
        }
        let stored: UInt32 = readLittleEndian(file, at: 16)
        var crc = CRC32C.Running()
        crc.update(file[4..<16])
        crc.update(file[headerSize...])
        guard crc.value == stored else { return .failure(.checksumMismatch) }
        return .success(Array(file[headerSize...]))
    }
}

func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    (0..<(T.bitWidth / 8)).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

func readLittleEndian<T: FixedWidthInteger>(_ bytes: [UInt8], at offset: Int) -> T {
    var value: T = 0
    for index in 0..<(T.bitWidth / 8) {
        value |= T(truncatingIfNeeded: bytes[offset + index]) << (index * 8)
    }
    return value
}
