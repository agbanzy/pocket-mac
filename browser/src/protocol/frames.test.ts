// Conformance tests for the wire frame codec — proves this TypeScript port produces and accepts
// exactly the same bytes as the Swift FrameCodec (mac/iOS) and the Go relay's frame passthrough.
// See frames.ts's header for the mirrored Swift sources and the record layout it documents.

import { describe, expect, it } from 'vitest';
import { BinaryWriter, CodecError } from './binary';
import {
  ControlOpcode,
  Frame,
  FrameDomain,
  Modifier,
  MouseButton,
  control,
  decodeFrame,
  encodeFrame,
  input,
} from './frames';

/**
 * Hand-builds a raw record so decodeFrame can be probed with domain/opcode byte values that
 * encodeFrame itself would never produce — the whole point is exercising the rejection path.
 */
function rawRecord(version: number, domain: number, opcode: number, payload: Uint8Array): Uint8Array {
  const w = new BinaryWriter();
  w.writeUInt8(version);
  w.writeUInt8(domain);
  w.writeUInt8(opcode);
  w.writeUInt16(payload.length);
  w.writeRaw(payload);
  return w.data;
}

describe('frames codec — round-trip', () => {
  const controlCases: Array<[string, Frame]> = [
    [
      'hello',
      control({
        t: 'hello',
        deviceName: "Guru's MacBook Pro",
        appVersion: '1.4.2',
        capabilities: 0xdeadbeef,
      }),
    ],
    ['ack', control({ t: 'ack', seq: 4294967295 })], // max u32
    ['error', control({ t: 'error', code: 7, message: 'session expired' })],
    ['ping', control({ t: 'ping', nonce: 1 })],
    ['pong', control({ t: 'pong', nonce: 99 })],
    ['startVideo', control({ t: 'startVideo', fps: 30 })],
    ['stopVideo', control({ t: 'stopVideo' })],
  ];

  const inputCases: Array<[string, Frame]> = [
    ['mouseMove', input({ t: 'mouseMove', dx: 12, dy: -34 })],
    ['mouseDown', input({ t: 'mouseDown', button: MouseButton.Left })],
    ['mouseUp', input({ t: 'mouseUp', button: MouseButton.Right })],
    ['mouseClick', input({ t: 'mouseClick', button: MouseButton.Middle, count: 2 })],
    ['scroll', input({ t: 'scroll', dx: 5, dy: -5 })],
    ['keyDown', input({ t: 'keyDown', keyCode: 36, modifiers: Modifier.Shift | Modifier.Command })],
    ['keyUp', input({ t: 'keyUp', keyCode: 36, modifiers: 0 })],
    ['unicodeText', input({ t: 'unicodeText', text: 'café ⌘' })], // multi-byte UTF-8: é (2B), ⌘ (3B)
    ['setModifiers', input({ t: 'setModifiers', modifiers: Modifier.CapsLock })],
    ['mouseMoveAbsolute', input({ t: 'mouseMoveAbsolute', x: 100, y: 200 })],
  ];

  const videoCase: [string, Frame] = [
    'video chunk',
    {
      domain: FrameDomain.Video,
      video: {
        frameID: 123456,
        chunkIndex: 1,
        chunkCount: 4,
        flags: 1,
        width: 1920,
        height: 1080,
        data: new Uint8Array([0, 1, 2, 3, 4, 250, 251, 252, 253, 254, 255]),
      },
    },
  ];

  for (const [name, frame] of [...controlCases, ...inputCases, videoCase]) {
    it(`round-trips ${name}`, () => {
      expect(decodeFrame(encodeFrame(frame))).toEqual(frame);
    });
  }

  it('round-trips mouseMove at the Int16 boundary (dx=-32768, dy=32767)', () => {
    const frame = input({ t: 'mouseMove', dx: -32768, dy: 32767 });
    expect(decodeFrame(encodeFrame(frame))).toEqual(frame);
  });

  it('round-trips mouseMoveAbsolute at the UInt16 boundary (x=0, y=65535)', () => {
    const frame = input({ t: 'mouseMoveAbsolute', x: 0, y: 65535 });
    expect(decodeFrame(encodeFrame(frame))).toEqual(frame);
  });
});

describe('frames codec — exact wire layout', () => {
  it('encodes control(ping) with the documented header: version, domain, opcode, u16 length', () => {
    const bytes = encodeFrame(control({ t: 'ping', nonce: 1 }));
    expect(bytes[0]).toBe(1); // WIRE_PROTOCOL_VERSION
    expect(bytes[1]).toBe(FrameDomain.Control);
    expect(bytes[2]).toBe(ControlOpcode.Ping);
    // u16 payload length, big-endian: a single u32 nonce == 4 bytes.
    expect(bytes[3]).toBe(0);
    expect(bytes[4]).toBe(4);
    expect(bytes.length).toBe(5 + 4);
  });
});

describe('frames codec — decode rejects unknown bytes', () => {
  it('throws CodecError on an unknown domain byte', () => {
    const record = rawRecord(1, 99, 0, new Uint8Array(0));
    expect(() => decodeFrame(record)).toThrow(CodecError);
  });

  it('throws CodecError on an unknown control opcode byte', () => {
    const record = rawRecord(1, FrameDomain.Control, 250, new Uint8Array(0));
    expect(() => decodeFrame(record)).toThrow(CodecError);
  });

  it('throws CodecError on an unknown input opcode byte', () => {
    const record = rawRecord(1, FrameDomain.Input, 250, new Uint8Array(0));
    expect(() => decodeFrame(record)).toThrow(CodecError);
  });
});
