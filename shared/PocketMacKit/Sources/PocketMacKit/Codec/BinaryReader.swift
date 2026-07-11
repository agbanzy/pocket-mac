import Foundation

/// A bounds-checked big-endian byte reader over `Data`. Every read validates remaining length
/// and throws ``CodecError/truncated(needed:available:)`` rather than trapping.
struct BinaryReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= count else {
            throw CodecError.truncated(needed: count, available: remaining)
        }
        let slice = bytes[offset ..< offset + count]
        offset += count
        return slice
    }

    mutating func readUInt8() throws -> UInt8 {
        try take(1).first!
    }

    mutating func readUInt16() throws -> UInt16 {
        let s = try take(2)
        let hi = UInt16(s[s.startIndex])
        let lo = UInt16(s[s.startIndex + 1])
        return (hi << 8) | lo
    }

    mutating func readUInt32() throws -> UInt32 {
        let s = try take(4)
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value = (value << 8) | UInt32(s[s.startIndex + i])
        }
        return value
    }

    mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    mutating func readUUID() throws -> UUID {
        let s = try take(16)
        let b = Array(s)
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt16())
        let s = try take(length)
        guard let string = String(bytes: s, encoding: .utf8) else {
            throw CodecError.invalidString
        }
        return string
    }

    mutating func readRaw(_ count: Int) throws -> Data {
        Data(try take(count))
    }
}
