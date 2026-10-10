/// CRC-32C (Castagnoli), the checksum of iSCSI, ext4 metadata and SQLite's
/// WAL variants.
///
/// Castagnoli's polynomial detects every burst error up to 32 bits and has
/// better Hamming distance than the CRC-32 of zlib for short messages, the
/// size of record this package frames. This is the plain table-driven
/// software form (reflected, polynomial `0x82F63B78`); files here are small
/// and the checksum is not the cost of a `fullSync`.
public enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0x82F6_3B78 : value >> 1
        }
        return value
    }

    /// The checksum of `bytes`. `checksum("123456789")` is `0xE3069283`.
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc = Running()
        crc.update(bytes)
        return crc.value
    }

    /// An incremental checksum, for data that arrives in pieces.
    public struct Running: Sendable {
        private var state: UInt32 = 0xFFFF_FFFF

        public init() {}

        public mutating func update(_ bytes: some Sequence<UInt8>) {
            var crc = state
            for byte in bytes {
                crc = CRC32C.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            state = crc
        }

        public var value: UInt32 { ~state }
    }
}
