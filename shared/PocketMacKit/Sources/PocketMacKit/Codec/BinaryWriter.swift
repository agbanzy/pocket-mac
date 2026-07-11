import Foundation

/// A minimal big-endian byte writer over `Data`. Big-endian ("network byte order") is the wire
/// convention for the whole protocol.
struct BinaryWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt16(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    /// Signed 16-bit, stored as its two's-complement bit pattern.
    mutating func writeInt16(_ value: Int16) {
        writeUInt16(UInt16(bitPattern: value))
    }

    /// A UUID as its raw 16 bytes.
    mutating func writeUUID(_ uuid: UUID) {
        let b = uuid.uuid
        data.append(contentsOf: [
            b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
            b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15,
        ])
    }

    /// A string as `[u16 byteLength][UTF-8 bytes]`.
    mutating func writeString(_ string: String) {
        let bytes = Data(string.utf8)
        // Strings longer than UInt16.max are not representable; the caller (FrameCodec) bounds
        // total payload size well below this, so this is defensive only.
        let length = UInt16(truncatingIfNeeded: bytes.count)
        writeUInt16(length)
        data.append(bytes)
    }

    mutating func writeRaw(_ raw: Data) {
        data.append(raw)
    }
}
