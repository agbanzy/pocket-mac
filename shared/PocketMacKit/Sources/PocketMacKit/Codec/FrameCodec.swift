import Foundation

/// A versioned encoder/decoder for ``Frame`` values. Abstracted behind a protocol so the wire
/// format can evolve without touching call sites.
public protocol FrameCoding: Sendable {
    func encode(_ frame: Frame) throws -> Data
    func decode(_ data: Data) throws -> Frame
}

/// Version-1 binary frame codec.
///
/// Record layout (big-endian):
/// ```
/// [u8 version][u8 domain][u8 opcode][u16 payloadLen][payload…]
/// ```
/// `payloadLen` bounds the payload so a decoder can skip an unknown-but-well-formed frame by its
/// declared length. Strings are `[u16 len][UTF-8]`. Unknown domain/opcode → ``CodecError/unsupported(domain:opcode:)``;
/// a wrong version byte → ``CodecError/unsupportedVersion(_:)``. Nothing here traps.
public struct FrameCodec: FrameCoding {
    /// Per-frame payload ceiling. `payloadLen` is a `UInt16`, so this is also its natural max.
    public static let maxPayloadSize = Int(UInt16.max)

    public init() {}

    // MARK: Encode

    public func encode(_ frame: Frame) throws -> Data {
        var payload = BinaryWriter()
        let opcode: UInt8

        switch frame {
        case .control(let c):
            opcode = c.opcode.rawValue
            encodeControl(c, into: &payload)
        case .input(let i):
            opcode = i.opcode.rawValue
            encodeInput(i, into: &payload)
        case .action(let a):
            opcode = a.action.opcode.rawValue
            encodeAction(a, into: &payload)
        }

        let payloadData = payload.data
        guard payloadData.count <= Self.maxPayloadSize else {
            throw CodecError.overlongLength(declared: payloadData.count, cap: Self.maxPayloadSize)
        }

        var record = BinaryWriter()
        record.writeUInt8(PocketMac.wireProtocolVersion)
        record.writeUInt8(frame.domain.rawValue)
        record.writeUInt8(opcode)
        record.writeUInt16(UInt16(payloadData.count))
        record.writeRaw(payloadData)
        return record.data
    }

    private func encodeControl(_ frame: ControlFrame, into w: inout BinaryWriter) {
        switch frame {
        case .hello(let p):
            w.writeString(p.deviceName)
            w.writeString(p.appVersion)
            w.writeUInt32(p.capabilities)
        case .ack(let seq):
            w.writeUInt32(seq)
        case .error(let code, let message):
            w.writeUInt8(code.rawValue)
            w.writeString(message)
        case .ping(let nonce):
            w.writeUInt32(nonce)
        case .pong(let nonce):
            w.writeUInt32(nonce)
        }
    }

    private func encodeInput(_ frame: InputFrame, into w: inout BinaryWriter) {
        switch frame {
        case .mouseMove(let dx, let dy):
            w.writeInt16(dx); w.writeInt16(dy)
        case .mouseDown(let button):
            w.writeUInt8(button.rawValue)
        case .mouseUp(let button):
            w.writeUInt8(button.rawValue)
        case .mouseClick(let button, let count):
            w.writeUInt8(button.rawValue); w.writeUInt8(count)
        case .scroll(let dx, let dy):
            w.writeInt16(dx); w.writeInt16(dy)
        case .keyDown(let keyCode, let modifiers):
            w.writeUInt16(keyCode); w.writeUInt8(modifiers.rawValue)
        case .keyUp(let keyCode, let modifiers):
            w.writeUInt16(keyCode); w.writeUInt8(modifiers.rawValue)
        case .unicodeText(let text):
            w.writeString(text)
        case .setModifiers(let modifiers):
            w.writeUInt8(modifiers.rawValue)
        }
    }

    private func encodeAction(_ frame: ActionFrame, into w: inout BinaryWriter) {
        w.writeUUID(frame.tileID)
        switch frame.action {
        case .launchApp(let bundleID):
            w.writeString(bundleID)
        case .runShortcut(let name):
            w.writeString(name)
        case .mediaKey(let key):
            w.writeUInt8(key.rawValue)
        case .systemControl(let control):
            w.writeUInt8(control.rawValue)
        }
    }

    // MARK: Decode

    public func decode(_ data: Data) throws -> Frame {
        var reader = BinaryReader(data)

        let version = try reader.readUInt8()
        guard version == PocketMac.wireProtocolVersion else {
            throw CodecError.unsupportedVersion(version)
        }
        let domainByte = try reader.readUInt8()
        let opcodeByte = try reader.readUInt8()
        let payloadLen = Int(try reader.readUInt16())

        guard payloadLen <= Self.maxPayloadSize else {
            throw CodecError.overlongLength(declared: payloadLen, cap: Self.maxPayloadSize)
        }
        // Isolate exactly the declared payload; trailing bytes (if any) are ignored so a newer
        // peer can append fields to a frame without breaking this decoder.
        let payloadData = try reader.readRaw(payloadLen)
        var payload = BinaryReader(payloadData)

        guard let domain = FrameDomain(rawValue: domainByte) else {
            throw CodecError.unsupported(domain: domainByte, opcode: opcodeByte)
        }

        switch domain {
        case .control:
            return .control(try decodeControl(opcodeByte, from: &payload))
        case .input:
            return .input(try decodeInput(opcodeByte, from: &payload))
        case .action:
            return .action(try decodeAction(opcodeByte, from: &payload))
        }
    }

    private func decodeControl(_ opcode: UInt8, from r: inout BinaryReader) throws -> ControlFrame {
        guard let op = ControlOpcode(rawValue: opcode) else {
            throw CodecError.unsupported(domain: FrameDomain.control.rawValue, opcode: opcode)
        }
        switch op {
        case .hello:
            let name = try r.readString()
            let version = try r.readString()
            let caps = try r.readUInt32()
            return .hello(HelloPayload(deviceName: name, appVersion: version, capabilities: caps))
        case .ack:
            return .ack(seq: try r.readUInt32())
        case .error:
            let raw = try r.readUInt8()
            let code = ProtocolErrorCode(rawValue: raw) ?? .unknown
            return .error(code: code, message: try r.readString())
        case .ping:
            return .ping(nonce: try r.readUInt32())
        case .pong:
            return .pong(nonce: try r.readUInt32())
        }
    }

    private func decodeInput(_ opcode: UInt8, from r: inout BinaryReader) throws -> InputFrame {
        guard let op = InputOpcode(rawValue: opcode) else {
            throw CodecError.unsupported(domain: FrameDomain.input.rawValue, opcode: opcode)
        }
        switch op {
        case .mouseMove:
            return .mouseMove(dx: try r.readInt16(), dy: try r.readInt16())
        case .mouseDown:
            return .mouseDown(try readButton(&r))
        case .mouseUp:
            return .mouseUp(try readButton(&r))
        case .mouseClick:
            let button = try readButton(&r)
            return .mouseClick(button: button, count: try r.readUInt8())
        case .scroll:
            return .scroll(dx: try r.readInt16(), dy: try r.readInt16())
        case .keyDown:
            let code = try r.readUInt16()
            return .keyDown(keyCode: code, modifiers: ModifierFlags(rawValue: try r.readUInt8()))
        case .keyUp:
            let code = try r.readUInt16()
            return .keyUp(keyCode: code, modifiers: ModifierFlags(rawValue: try r.readUInt8()))
        case .unicodeText:
            return .unicodeText(try r.readString())
        case .setModifiers:
            return .setModifiers(ModifierFlags(rawValue: try r.readUInt8()))
        }
    }

    private func decodeAction(_ opcode: UInt8, from r: inout BinaryReader) throws -> ActionFrame {
        guard let op = ActionOpcode(rawValue: opcode) else {
            throw CodecError.unsupported(domain: FrameDomain.action.rawValue, opcode: opcode)
        }
        let tileID = try r.readUUID()
        let action: TileAction
        switch op {
        case .launchApp:
            action = .launchApp(bundleID: try r.readString())
        case .runShortcut:
            action = .runShortcut(name: try r.readString())
        case .mediaKey:
            let raw = try r.readUInt8()
            guard let key = MediaKey(rawValue: raw) else {
                throw CodecError.invalidEnum(field: "MediaKey", value: UInt64(raw))
            }
            action = .mediaKey(key)
        case .systemControl:
            let raw = try r.readUInt8()
            guard let control = SystemControl(rawValue: raw) else {
                throw CodecError.invalidEnum(field: "SystemControl", value: UInt64(raw))
            }
            action = .systemControl(control)
        }
        return ActionFrame(tileID: tileID, action: action)
    }

    private func readButton(_ r: inout BinaryReader) throws -> MouseButton {
        let raw = try r.readUInt8()
        guard let button = MouseButton(rawValue: raw) else {
            throw CodecError.invalidEnum(field: "MouseButton", value: UInt64(raw))
        }
        return button
    }
}
