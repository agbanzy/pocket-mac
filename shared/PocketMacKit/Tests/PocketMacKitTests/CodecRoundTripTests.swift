import Foundation
import Testing
@testable import PocketMacKit

@Suite("Frame codec round-trip + rejection")
struct CodecRoundTripTests {
    let codec = FrameCodec()

    /// Every representative frame value, one per opcode across all three domains.
    static let allFrames: [Frame] = [
        // control
        .control(.hello(HelloPayload(deviceName: "Godwin’s iPhone", appVersion: "1.0.0", capabilities: 0xDEAD_BEEF))),
        .control(.ack(seq: 0x0102_0304)),
        .control(.error(code: .rateLimited, message: "slow down")),
        .control(.ping(nonce: 42)),
        .control(.pong(nonce: 42)),
        // input
        .input(.mouseMove(dx: -321, dy: 17)),
        .input(.mouseMove(dx: Int16.min, dy: Int16.max)),
        .input(.mouseDown(.left)),
        .input(.mouseUp(.right)),
        .input(.mouseClick(button: .middle, count: 2)),
        .input(.scroll(dx: 0, dy: -120)),
        .input(.keyDown(keyCode: 0x24, modifiers: [.command, .shift])),
        .input(.keyUp(keyCode: 0x00, modifiers: [])),
        .input(.unicodeText("héllo 🌍 — ünïcode")),
        .input(.setModifiers([.control, .option, .function])),
        // action
        .action(ActionFrame(tileID: UUID(), action: .launchApp(bundleID: "com.apple.Music"))),
        .action(ActionFrame(tileID: UUID(), action: .runShortcut(name: "Start Work Block"))),
        .action(ActionFrame(tileID: UUID(), action: .mediaKey(.playPause))),
        .action(ActionFrame(tileID: UUID(), action: .systemControl(.lock))),
    ]

    @Test("round-trips every frame type", arguments: allFrames)
    func roundTrip(_ frame: Frame) throws {
        let encoded = try codec.encode(frame)
        let decoded = try codec.decode(encoded)
        #expect(decoded == frame)
    }

    @Test("mouseMove encodes to a tight 5-byte header + 4-byte payload")
    func mouseMoveIsCompact() throws {
        let encoded = try codec.encode(.input(.mouseMove(dx: 1, dy: -1)))
        #expect(encoded.count == 9) // 1 ver + 1 domain + 1 opcode + 2 len + 4 payload
    }

    @Test("decode rejects a truncated buffer")
    func rejectsTruncated() throws {
        let encoded = try codec.encode(.input(.mouseMove(dx: 10, dy: 20)))
        let truncated = encoded.prefix(encoded.count - 2) // chop payload bytes
        #expect(throws: CodecError.self) {
            _ = try codec.decode(Data(truncated))
        }
    }

    @Test("decode rejects an unknown domain")
    func rejectsUnknownDomain() {
        // version=1, domain=99 (unknown), opcode=0, payloadLen=0
        let raw = Data([PocketMac.wireProtocolVersion, 99, 0, 0, 0])
        #expect(throws: CodecError.self) {
            _ = try codec.decode(raw)
        }
    }

    @Test("decode rejects an unknown opcode within a known domain")
    func rejectsUnknownOpcode() {
        // domain=input(1), opcode=200 (unknown), payloadLen=0
        let raw = Data([PocketMac.wireProtocolVersion, FrameDomain.input.rawValue, 200, 0, 0])
        #expect(throws: CodecError.self) {
            _ = try codec.decode(raw)
        }
    }

    @Test("decode rejects a wrong protocol version")
    func rejectsWrongVersion() {
        let raw = Data([UInt8(0xFE), FrameDomain.control.rawValue, ControlOpcode.ping.rawValue, 0, 4, 0, 0, 0, 1])
        #expect(throws: CodecError.self) {
            _ = try codec.decode(raw)
        }
    }

    @Test("decode of an unknown-but-well-formed frame ignores trailing appended bytes")
    func toleratesTrailingBytes() throws {
        // A future peer appends an extra field after a ping's nonce; payloadLen still bounds it.
        var w = BinaryWriter()
        w.writeUInt8(PocketMac.wireProtocolVersion)
        w.writeUInt8(FrameDomain.control.rawValue)
        w.writeUInt8(ControlOpcode.ping.rawValue)
        w.writeUInt16(4)              // declared payload = 4 (the nonce)
        w.writeUInt32(7)             // the nonce
        w.writeRaw(Data([0xAA, 0xBB])) // trailing bytes beyond payloadLen — must be ignored
        let decoded = try codec.decode(w.data)
        #expect(decoded == .control(.ping(nonce: 7)))
    }

    @Test("decode rejects an invalid enum value")
    func rejectsInvalidEnum() throws {
        // action / mediaKey with a bogus key byte
        var w = BinaryWriter()
        w.writeUInt8(PocketMac.wireProtocolVersion)
        w.writeUInt8(FrameDomain.action.rawValue)
        w.writeUInt8(ActionOpcode.mediaKey.rawValue)
        var payload = BinaryWriter()
        payload.writeUUID(UUID())
        payload.writeUInt8(250) // not a valid MediaKey
        w.writeUInt16(UInt16(payload.data.count))
        w.writeRaw(payload.data)
        #expect(throws: CodecError.self) {
            _ = try codec.decode(w.data)
        }
    }
}
