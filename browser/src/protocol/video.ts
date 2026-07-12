// Reassembles VideoChunks into whole Annex-B frames, in order, dropping incomplete ones.
// Mirror of `VideoReassembler` in
//   shared/PocketMacKit/Sources/PocketMacKit/Protocol/VideoFrame.swift
//
// The Mac splits each encoded H.264 frame into <=~60 KB chunks; we reassemble by frameID.

import { isKeyframe, VideoChunk } from './frames';

export interface ReassembledFrame {
  annexB: Uint8Array;
  isKeyframe: boolean;
  width: number;
  height: number;
}

export class VideoReassembler {
  private currentFrameID: number | null = null;
  private received = new Map<number, Uint8Array>();
  private expected = 0;

  /** Feeds a chunk; returns the complete frame when its last chunk arrives, else null. */
  accept(chunk: VideoChunk): ReassembledFrame | null {
    if (chunk.frameID !== this.currentFrameID) {
      this.currentFrameID = chunk.frameID;
      this.received = new Map();
      this.expected = chunk.chunkCount;
    }
    this.received.set(chunk.chunkIndex, chunk.data);
    if (this.received.size !== this.expected) return null;

    // All chunks present: concatenate in index order. A gap -> drop the frame.
    const parts: Uint8Array[] = [];
    let total = 0;
    for (let i = 0; i < this.expected; i++) {
      const part = this.received.get(i);
      if (!part) return null;
      parts.push(part);
      total += part.length;
    }
    const annexB = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      annexB.set(part, offset);
      offset += part.length;
    }

    const result: ReassembledFrame = {
      annexB,
      isKeyframe: isKeyframe(chunk),
      width: chunk.width,
      height: chunk.height,
    };
    this.received = new Map();
    this.currentFrameID = null;
    return result;
  }
}
