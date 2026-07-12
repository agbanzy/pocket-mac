// The wire frame model + version-1 codec. Byte-for-byte mirror of:
//   shared/PocketMacKit/Sources/PocketMacKit/Protocol/{WireFrame,ControlFrame,InputFrame,ActionFrame,VideoFrame}.swift
//   shared/PocketMacKit/Sources/PocketMacKit/Codec/FrameCodec.swift
//
// Record layout (big-endian):
//   [u8 version=1][u8 domain][u8 opcode][u16 payloadLen][payload…]
// Strings are [u16 len][UTF-8]. Unknown domain/opcode -> throws (never traps).

import { BinaryReader, BinaryWriter, CodecError } from './binary';

/** First byte of every encoded frame. PocketMac.wireProtocolVersion == 1. */
export const WIRE_PROTOCOL_VERSION = 1;
/** payloadLen is a UInt16, so this is the natural per-frame payload ceiling. */
export const MAX_PAYLOAD_SIZE = 0xffff;

// The four top-level frame domains (second byte of every record).
export enum FrameDomain {
  Control = 0,
  Input = 1,
  Action = 2,
  Video = 3,
}

// Control-domain opcodes (ControlFrame.swift).
export enum ControlOpcode {
  Hello = 0,
  Ack = 1,
  Error = 2,
  Ping = 3,
  Pong = 4,
  StartVideo = 5,
  StopVideo = 6,
}

// Input-domain opcodes (InputFrame.swift).
export enum InputOpcode {
  MouseMove = 0,
  MouseDown = 1,
  MouseUp = 2,
  MouseClick = 3,
  Scroll = 4,
  KeyDown = 5,
  KeyUp = 6,
  UnicodeText = 7,
  SetModifiers = 8,
  MouseMoveAbsolute = 9,
}

// Physical mouse buttons (InputFrame.swift MouseButton).
export enum MouseButton {
  Left = 0,
  Right = 1,
  Middle = 2,
}

// Keyboard modifier bitflags (InputFrame.swift ModifierFlags). Bit layout is the wire contract.
export const Modifier = {
  Shift: 1 << 0,
  Control: 1 << 1,
  Option: 1 << 2,
  Command: 1 << 3,
  Function: 1 << 4,
  CapsLock: 1 << 5,
} as const;

// ---- Frame value model (a discriminated union mirroring the Swift `Frame` enum) ----

export type ControlFrame =
  | { t: 'hello'; deviceName: string; appVersion: string; capabilities: number }
  | { t: 'ack'; seq: number }
  | { t: 'error'; code: number; message: string }
  | { t: 'ping'; nonce: number }
  | { t: 'pong'; nonce: number }
  | { t: 'startVideo'; fps: number }
  | { t: 'stopVideo' };

export type InputFrame =
  | { t: 'mouseMove'; dx: number; dy: number }
  | { t: 'mouseDown'; button: MouseButton }
  | { t: 'mouseUp'; button: MouseButton }
  | { t: 'mouseClick'; button: MouseButton; count: number }
  | { t: 'scroll'; dx: number; dy: number }
  | { t: 'keyDown'; keyCode: number; modifiers: number }
  | { t: 'keyUp'; keyCode: number; modifiers: number }
  | { t: 'unicodeText'; text: string }
  | { t: 'setModifiers'; modifiers: number }
  | { t: 'mouseMoveAbsolute'; x: number; y: number };

export interface VideoChunk {
  frameID: number;
  chunkIndex: number;
  chunkCount: number;
  flags: number; // bit 0 = keyframe (IDR)
  width: number;
  height: number;
  data: Uint8Array;
}

export type Frame =
  | { domain: FrameDomain.Control; control: ControlFrame }
  | { domain: FrameDomain.Input; input: InputFrame }
  | { domain: FrameDomain.Video; video: VideoChunk };
// Action frames (deck tiles) are Mac-inbound only; the browser never emits them, so they are
// intentionally omitted from the outbound model. The decoder still rejects them cleanly if seen.

// ---- Convenience constructors ----

export const control = (c: ControlFrame): Frame => ({ domain: FrameDomain.Control, control: c });
export const input = (i: InputFrame): Frame => ({ domain: FrameDomain.Input, input: i });

// ---- Encode (mirror FrameCodec.encode) ----

export function encodeFrame(frame: Frame): Uint8Array {
  const payload = new BinaryWriter();
  let opcode: number;

  switch (frame.domain) {
    case FrameDomain.Control:
      opcode = encodeControl(frame.control, payload);
      break;
    case FrameDomain.Input:
      opcode = encodeInput(frame.input, payload);
      break;
    case FrameDomain.Video:
      opcode = 0;
      encodeVideo(frame.video, payload);
      break;
  }

  const payloadData = payload.data;
  if (payloadData.length > MAX_PAYLOAD_SIZE) {
    throw new CodecError(`overlong payload: ${payloadData.length} > ${MAX_PAYLOAD_SIZE}`);
  }

  const record = new BinaryWriter();
  record.writeUInt8(WIRE_PROTOCOL_VERSION);
  record.writeUInt8(frame.domain);
  record.writeUInt8(opcode);
  record.writeUInt16(payloadData.length);
  record.writeRaw(payloadData);
  return record.data;
}

function encodeControl(c: ControlFrame, w: BinaryWriter): number {
  switch (c.t) {
    case 'hello':
      w.writeString(c.deviceName);
      w.writeString(c.appVersion);
      w.writeUInt32(c.capabilities >>> 0);
      return ControlOpcode.Hello;
    case 'ack':
      w.writeUInt32(c.seq >>> 0);
      return ControlOpcode.Ack;
    case 'error':
      w.writeUInt8(c.code);
      w.writeString(c.message);
      return ControlOpcode.Error;
    case 'ping':
      w.writeUInt32(c.nonce >>> 0);
      return ControlOpcode.Ping;
    case 'pong':
      w.writeUInt32(c.nonce >>> 0);
      return ControlOpcode.Pong;
    case 'startVideo':
      w.writeUInt8(c.fps);
      return ControlOpcode.StartVideo;
    case 'stopVideo':
      return ControlOpcode.StopVideo;
  }
}

function encodeInput(i: InputFrame, w: BinaryWriter): number {
  switch (i.t) {
    case 'mouseMove':
      w.writeInt16(i.dx);
      w.writeInt16(i.dy);
      return InputOpcode.MouseMove;
    case 'mouseDown':
      w.writeUInt8(i.button);
      return InputOpcode.MouseDown;
    case 'mouseUp':
      w.writeUInt8(i.button);
      return InputOpcode.MouseUp;
    case 'mouseClick':
      w.writeUInt8(i.button);
      w.writeUInt8(i.count);
      return InputOpcode.MouseClick;
    case 'scroll':
      w.writeInt16(i.dx);
      w.writeInt16(i.dy);
      return InputOpcode.Scroll;
    case 'keyDown':
      w.writeUInt16(i.keyCode);
      w.writeUInt8(i.modifiers);
      return InputOpcode.KeyDown;
    case 'keyUp':
      w.writeUInt16(i.keyCode);
      w.writeUInt8(i.modifiers);
      return InputOpcode.KeyUp;
    case 'unicodeText':
      w.writeString(i.text);
      return InputOpcode.UnicodeText;
    case 'setModifiers':
      w.writeUInt8(i.modifiers);
      return InputOpcode.SetModifiers;
    case 'mouseMoveAbsolute':
      w.writeUInt16(i.x);
      w.writeUInt16(i.y);
      return InputOpcode.MouseMoveAbsolute;
  }
}

function encodeVideo(v: VideoChunk, w: BinaryWriter): void {
  w.writeUInt32(v.frameID >>> 0);
  w.writeUInt16(v.chunkIndex);
  w.writeUInt16(v.chunkCount);
  w.writeUInt8(v.flags);
  w.writeUInt16(v.width);
  w.writeUInt16(v.height);
  w.writeRaw(v.data);
}

// ---- Decode (mirror FrameCodec.decode) ----

export function decodeFrame(data: Uint8Array): Frame {
  const reader = new BinaryReader(data);
  const version = reader.readUInt8();
  if (version !== WIRE_PROTOCOL_VERSION) {
    throw new CodecError(`unsupported version ${version}`);
  }
  const domainByte = reader.readUInt8();
  const opcodeByte = reader.readUInt8();
  const payloadLen = reader.readUInt16();
  if (payloadLen > MAX_PAYLOAD_SIZE) {
    throw new CodecError(`overlong length ${payloadLen}`);
  }
  // Isolate exactly the declared payload; trailing bytes are ignored so a newer peer can append.
  const payload = new BinaryReader(reader.readRaw(payloadLen));

  switch (domainByte) {
    case FrameDomain.Control:
      return control(decodeControl(opcodeByte, payload));
    case FrameDomain.Input:
      return input(decodeInput(opcodeByte, payload));
    case FrameDomain.Video:
      return { domain: FrameDomain.Video, video: decodeVideo(payload) };
    default:
      throw new CodecError(`unsupported domain ${domainByte} opcode ${opcodeByte}`);
  }
}

function decodeControl(opcode: number, r: BinaryReader): ControlFrame {
  switch (opcode) {
    case ControlOpcode.Hello:
      return {
        t: 'hello',
        deviceName: r.readString(),
        appVersion: r.readString(),
        capabilities: r.readUInt32(),
      };
    case ControlOpcode.Ack:
      return { t: 'ack', seq: r.readUInt32() };
    case ControlOpcode.Error:
      return { t: 'error', code: r.readUInt8(), message: r.readString() };
    case ControlOpcode.Ping:
      return { t: 'ping', nonce: r.readUInt32() };
    case ControlOpcode.Pong:
      return { t: 'pong', nonce: r.readUInt32() };
    case ControlOpcode.StartVideo:
      return { t: 'startVideo', fps: r.readUInt8() };
    case ControlOpcode.StopVideo:
      return { t: 'stopVideo' };
    default:
      throw new CodecError(`unsupported control opcode ${opcode}`);
  }
}

function decodeInput(opcode: number, r: BinaryReader): InputFrame {
  switch (opcode) {
    case InputOpcode.MouseMove:
      return { t: 'mouseMove', dx: r.readInt16(), dy: r.readInt16() };
    case InputOpcode.MouseDown:
      return { t: 'mouseDown', button: readButton(r) };
    case InputOpcode.MouseUp:
      return { t: 'mouseUp', button: readButton(r) };
    case InputOpcode.MouseClick:
      return { t: 'mouseClick', button: readButton(r), count: r.readUInt8() };
    case InputOpcode.Scroll:
      return { t: 'scroll', dx: r.readInt16(), dy: r.readInt16() };
    case InputOpcode.KeyDown:
      return { t: 'keyDown', keyCode: r.readUInt16(), modifiers: r.readUInt8() };
    case InputOpcode.KeyUp:
      return { t: 'keyUp', keyCode: r.readUInt16(), modifiers: r.readUInt8() };
    case InputOpcode.UnicodeText:
      return { t: 'unicodeText', text: r.readString() };
    case InputOpcode.SetModifiers:
      return { t: 'setModifiers', modifiers: r.readUInt8() };
    case InputOpcode.MouseMoveAbsolute:
      return { t: 'mouseMoveAbsolute', x: r.readUInt16(), y: r.readUInt16() };
    default:
      throw new CodecError(`unsupported input opcode ${opcode}`);
  }
}

function decodeVideo(r: BinaryReader): VideoChunk {
  const frameID = r.readUInt32();
  const chunkIndex = r.readUInt16();
  const chunkCount = r.readUInt16();
  const flags = r.readUInt8();
  const width = r.readUInt16();
  const height = r.readUInt16();
  const data = r.readRaw(r.remaining);
  return { frameID, chunkIndex, chunkCount, flags, width, height, data };
}

function readButton(r: BinaryReader): MouseButton {
  const raw = r.readUInt8();
  if (raw > 2) throw new CodecError(`invalid MouseButton ${raw}`);
  return raw as MouseButton;
}

export const isKeyframe = (chunk: VideoChunk): boolean => (chunk.flags & 0x1) !== 0;
