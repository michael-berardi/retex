import Foundation

/// Builds small stored (uncompressed) ZIP archives byte-by-byte so tests can
/// craft entries real tools would not produce: lying sizes, duplicate names,
/// missing file-type bits, or bad checksums.
struct ZIPFixture {
    struct Entry {
        var name: String
        var data: Data
        /// Uncompressed size written to the headers; defaults to the real size.
        var declaredSize: Int?
        /// Unix mode stored in the high 16 bits of the external attributes.
        var unixMode: UInt32 = 0o100644
        var corruptChecksum = false
    }

    var entries: [Entry] = []

    mutating func add(_ name: String, _ data: Data, declaredSize: Int? = nil, unixMode: UInt32 = 0o100644, corruptChecksum: Bool = false) {
        entries.append(Entry(name: name, data: data, declaredSize: declaredSize, unixMode: unixMode, corruptChecksum: corruptChecksum))
    }

    func data() -> Data {
        var archive = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let checksum = Self.crc32(entry.data) ^ (entry.corruptChecksum ? 0xFFFF_FFFF : 0)
            let size = UInt32(entry.data.count)
            let declared = UInt32(entry.declaredSize ?? entry.data.count)
            let offset = UInt32(archive.count)

            archive.append(le32: 0x0403_4B50)
            archive.append(le16: 20)
            archive.append(le16: 0)
            archive.append(le16: 0)
            archive.append(le16: 0)
            archive.append(le16: 0x21)
            archive.append(le32: checksum)
            archive.append(le32: size)
            archive.append(le32: declared)
            archive.append(le16: UInt16(name.count))
            archive.append(le16: 0)
            archive.append(name)
            archive.append(entry.data)

            central.append(le32: 0x0201_4B50)
            central.append(le16: 3 << 8 | 20)
            central.append(le16: 20)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0x21)
            central.append(le32: checksum)
            central.append(le32: size)
            central.append(le32: declared)
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le32: entry.unixMode << 16)
            central.append(le32: offset)
            central.append(name)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(le32: 0x0605_4B50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(entries.count))
        archive.append(le16: UInt16(entries.count))
        archive.append(le32: UInt32(central.count))
        archive.append(le32: centralOffset)
        archive.append(le16: 0)
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
