// Big-endian byte reader/writer, byte-for-byte mirror of the Swift wire codec.
//
// Mirrors:
//   shared/PocketMacKit/Sources/PocketMacKit/Codec/BinaryWriter.swift
//   shared/PocketMacKit/Sources/PocketMacKit/Codec/BinaryReader.swift
//
// Every multi-byte integer is big-endian ("network byte order"). Strings are
// [u16 byteLength][UTF-8 bytes]. UUIDs are their raw 16 bytes. These conventions
// are the wire contract — do not change them.

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

/** A minimal big-endian byte writer over a growable buffer. */
export class BinaryWriter {
  private chunks: number[] = [];

  writeUInt8(value: number): void {
    this.chunks.push(value & 0xff);
  }

  writeUInt16(value: number): void {
    this.chunks.push((value >>> 8) & 0xff, value & 0xff);
  }

  writeUInt32(value: number): void {
    this.chunks.push(
      (value >>> 24) & 0xff,
      (value >>> 16) & 0xff,
      (value >>> 8) & 0xff,
      value & 0xff,
    );
  }

  /** Signed 16-bit, stored as its two's-complement bit pattern. */
  writeInt16(value: number): void {
    this.writeUInt16(value & 0xffff);
  }

  /** A UUID passed as its raw 16 bytes. */
  writeUUID(uuid: Uint8Array): void {
    if (uuid.length !== 16) throw new Error('UUID must be 16 bytes');
    for (let i = 0; i < 16; i++) this.chunks.push(uuid[i]);
  }

  /** A string as [u16 byteLength][UTF-8 bytes]. */
  writeString(value: string): void {
    const bytes = utf8Encoder.encode(value);
    // FrameCodec bounds total payload well below UInt16.max; truncatingIfNeeded is defensive-only.
    this.writeUInt16(bytes.length & 0xffff);
    for (let i = 0; i < bytes.length; i++) this.chunks.push(bytes[i]);
  }

  writeRaw(raw: Uint8Array): void {
    for (let i = 0; i < raw.length; i++) this.chunks.push(raw[i]);
  }

  get data(): Uint8Array {
    return Uint8Array.from(this.chunks);
  }
}

/** Errors thrown while decoding — the codec never throws a raw RangeError on bad input. */
export class CodecError extends Error {}

/** A bounds-checked big-endian byte reader over a Uint8Array. */
export class BinaryReader {
  private offset = 0;
  constructor(private readonly bytes: Uint8Array) {}

  get remaining(): number {
    return this.bytes.length - this.offset;
  }

  get isAtEnd(): boolean {
    return this.offset >= this.bytes.length;
  }

  private take(count: number): Uint8Array {
    if (this.remaining < count) {
      throw new CodecError(`truncated: needed ${count}, available ${this.remaining}`);
    }
    const slice = this.bytes.subarray(this.offset, this.offset + count);
    this.offset += count;
    return slice;
  }

  readUInt8(): number {
    return this.take(1)[0];
  }

  readUInt16(): number {
    const s = this.take(2);
    return ((s[0] << 8) | s[1]) >>> 0;
  }

  readUInt32(): number {
    const s = this.take(4);
    return ((s[0] << 24) | (s[1] << 16) | (s[2] << 8) | s[3]) >>> 0;
  }

  readInt16(): number {
    const v = this.readUInt16();
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  readUUID(): Uint8Array {
    return Uint8Array.from(this.take(16));
  }

  readString(): string {
    const length = this.readUInt16();
    const s = this.take(length);
    try {
      return utf8Decoder.decode(s);
    } catch {
      throw new CodecError('invalid UTF-8 string');
    }
  }

  readRaw(count: number): Uint8Array {
    return Uint8Array.from(this.take(count));
  }
}
