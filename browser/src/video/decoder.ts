// Decodes the Mac's Annex-B H.264 screen stream with WebCodecs and paints it to a canvas.
//
// Counterpart: mac/PocketMacHelper/Streaming/ScreenStreamer.swift produces this Annex-B stream
// (VideoToolbox, kVTProfileLevel_H264_High_AutoLevel, in-band SPS/PPS, IDR every 2s). iOS decodes
// the identical stream via AVSampleBufferDisplayLayer; the browser has no CoreMedia equivalent, so
// this uses the WebCodecs VideoDecoder instead.
//
// Annex-B carries SPS/PPS in-band, so `configure()` is called WITHOUT a `description` — the decoder
// parses parameter sets straight out of the bitstream. The `codec` string it still needs upfront is
// hand-parsed out of the first keyframe's SPS NAL (see `deriveCodec` below).

import { ReassembledFrame } from '../protocol/video';

const MICROS_PER_FRAME = 33_333; // ~30fps monotonic clock for EncodedVideoChunk.timestamp
const FALLBACK_CODEC = 'avc1.640028'; // High profile / level 4.0 — used only if no SPS is found

interface NalUnit {
  type: number; // nal_unit_type: low 5 bits of the NAL header byte
  headerOffset: number; // index of that header byte within the buffer
}

/**
 * Scans an Annex-B byte stream for NAL start codes (3-byte `00 00 01` or 4-byte `00 00 00 01`)
 * and returns each unit's type and header-byte offset. Deliberately doesn't compute NAL end
 * boundaries — callers that need SPS fields read them at fixed offsets past the header.
 */
function scanAnnexBNalUnits(data: Uint8Array): NalUnit[] {
  const nals: NalUnit[] = [];
  const len = data.length;
  let i = 0;
  while (i + 3 <= len) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      const headerOffset = i + 3;
      if (headerOffset < len) nals.push({ type: data[headerOffset] & 0x1f, headerOffset });
      i = headerOffset;
      continue;
    }
    if (i + 4 <= len && data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 0 && data[i + 3] === 1) {
      const headerOffset = i + 4;
      if (headerOffset < len) nals.push({ type: data[headerOffset] & 0x1f, headerOffset });
      i = headerOffset;
      continue;
    }
    i += 1;
  }
  return nals;
}

/** `avc1.` + profile_idc/constraint-flags/level_idc from the SPS, or FALLBACK_CODEC if none found. */
function deriveCodec(annexB: Uint8Array): string {
  const sps = scanAnnexBNalUnits(annexB).find((nal) => nal.type === 7);
  if (!sps || sps.headerOffset + 3 >= annexB.length) return FALLBACK_CODEC;
  const hex = (byte: number) => byte.toString(16).padStart(2, '0').toUpperCase();
  const profileIdc = annexB[sps.headerOffset + 1];
  const constraintByte = annexB[sps.headerOffset + 2];
  const levelIdc = annexB[sps.headerOffset + 3];
  return `avc1.${hex(profileIdc)}${hex(constraintByte)}${hex(levelIdc)}`;
}

/** Decodes the Mac's Annex-B H.264 stream with WebCodecs and paints frames onto `canvas`. */
export class ScreenDecoder {
  private readonly unsupported: boolean;
  private decoder: VideoDecoder | null = null;
  private ctx: CanvasRenderingContext2D | null = null;
  private needsKeyframe = true;
  private closed = false;
  private nextTimestampUs = 0;
  private lastErrorMessage: string | null = null;

  constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly onError?: (e: Error) => void,
  ) {
    this.unsupported = typeof VideoDecoder === 'undefined';
  }

  /** Feeds one reassembled frame. Drops it while waiting on a keyframe (initially, or after an error). */
  push(frame: ReassembledFrame): void {
    if (this.unsupported) {
      this.reportOnce('WebCodecs unavailable — use Chrome or Edge');
      return;
    }
    if (this.closed) return;
    if (this.needsKeyframe && !frame.isKeyframe) return; // only a keyframe may (re)start decode

    try {
      if (!this.decoder) this.configure(frame);
      this.decodeChunk(frame);
      if (frame.isKeyframe) this.needsKeyframe = false;
    } catch (err) {
      this.fail(err);
    }
  }

  /** Closes the underlying VideoDecoder, if any. Idempotent; pushes after this are ignored. */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    if (this.decoder && this.decoder.state !== 'closed') this.decoder.close();
    this.decoder = null;
  }

  // ---- Configure + decode ----

  private configure(frame: ReassembledFrame): void {
    const codec = deriveCodec(frame.annexB);
    const decoder = new VideoDecoder({
      output: (videoFrame) => this.paint(videoFrame),
      error: (e) => this.fail(e),
    });
    decoder.configure({ codec, optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware' });
    this.decoder = decoder; // only assigned once configure() above didn't throw
  }

  private decodeChunk(frame: ReassembledFrame): void {
    if (!this.decoder) return; // unreachable in practice: configure() would have thrown first
    const chunk = new EncodedVideoChunk({
      type: frame.isKeyframe ? 'key' : 'delta',
      timestamp: this.nextTimestampUs,
      data: frame.annexB,
    });
    this.nextTimestampUs += MICROS_PER_FRAME;
    this.decoder.decode(chunk);
  }

  private paint(videoFrame: VideoFrame): void {
    try {
      if (this.canvas.width !== videoFrame.displayWidth || this.canvas.height !== videoFrame.displayHeight) {
        this.canvas.width = videoFrame.displayWidth;
        this.canvas.height = videoFrame.displayHeight;
      }
      if (!this.ctx) this.ctx = this.canvas.getContext('2d');
      this.ctx?.drawImage(videoFrame, 0, 0, this.canvas.width, this.canvas.height);
    } finally {
      videoFrame.close(); // mandatory — an unclosed VideoFrame leaks and stalls the decoder
    }
  }

  // ---- Error handling / recovery ----

  /**
   * WebCodecs closes the codec internally before an `error` callback fires, so the VideoDecoder
   * that produced it can never decode again. Drop the reference and gate on `needsKeyframe`; the
   * next keyframe lazily builds a fresh decoder via `configure`. Also the shared catch target for
   * any synchronous throw out of `configure`/`decodeChunk` — never rethrown out of `push`.
   */
  private fail(err: unknown): void {
    this.needsKeyframe = true;
    this.decoder = null;
    const message = err instanceof Error ? err.message : String(err);
    this.reportOnce(message, err instanceof Error ? err : new Error(message));
  }

  private reportOnce(message: string, error: Error = new Error(message)): void {
    if (message === this.lastErrorMessage) return;
    this.lastErrorMessage = message;
    this.onError?.(error);
  }
}
