// Conformance tests for VideoReassembler — proves this port reassembles chunked H.264 Annex-B
// frames identically to the Swift VideoReassembler: order-independent by chunkIndex, dropping
// incomplete sets, and resetting cleanly when a new frameID interrupts a partial one.
// See video.ts's header for the mirrored Swift source.

import { describe, expect, it } from 'vitest';
import { VideoChunk } from './frames';
import { VideoReassembler } from './video';

function chunk(
  overrides: Partial<VideoChunk> & Pick<VideoChunk, 'frameID' | 'chunkIndex' | 'chunkCount' | 'data'>,
): VideoChunk {
  return { flags: 0, width: 1280, height: 720, ...overrides };
}

describe('VideoReassembler', () => {
  it('reassembles out-of-order chunks into one frame, concatenated in index order', () => {
    const reassembler = new VideoReassembler();
    const part0 = new Uint8Array([1, 2, 3]);
    const part1 = new Uint8Array([4, 5]);
    const part2 = new Uint8Array([6, 7, 8, 9]);

    // Delivered out of order: index 2, then 0, then 1.
    expect(
      reassembler.accept(
        chunk({ frameID: 5, chunkIndex: 2, chunkCount: 3, data: part2, flags: 1, width: 1920, height: 1080 }),
      ),
    ).toBeNull();
    expect(
      reassembler.accept(
        chunk({ frameID: 5, chunkIndex: 0, chunkCount: 3, data: part0, flags: 1, width: 1920, height: 1080 }),
      ),
    ).toBeNull();
    const result = reassembler.accept(
      chunk({ frameID: 5, chunkIndex: 1, chunkCount: 3, data: part1, flags: 1, width: 1920, height: 1080 }),
    );

    expect(result).not.toBeNull();
    expect(result!.annexB).toEqual(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect(result!.width).toBe(1920);
    expect(result!.height).toBe(1080);
    expect(result!.isKeyframe).toBe(true);
  });

  it('returns null while a frame is still incomplete', () => {
    const reassembler = new VideoReassembler();
    expect(
      reassembler.accept(chunk({ frameID: 9, chunkIndex: 0, chunkCount: 3, data: new Uint8Array([1]) })),
    ).toBeNull();
    expect(
      reassembler.accept(chunk({ frameID: 9, chunkIndex: 1, chunkCount: 3, data: new Uint8Array([2]) })),
    ).toBeNull();
  });

  it('resets state when a new frameID arrives mid-stream, discarding the stale partial frame', () => {
    const reassembler = new VideoReassembler();
    // Frame 1 starts; 2 of its 3 chunks arrive.
    expect(
      reassembler.accept(chunk({ frameID: 1, chunkIndex: 0, chunkCount: 3, data: new Uint8Array([1]) })),
    ).toBeNull();
    expect(
      reassembler.accept(chunk({ frameID: 1, chunkIndex: 1, chunkCount: 3, data: new Uint8Array([2]) })),
    ).toBeNull();

    // Frame 2 begins before frame 1 finished — its own 2 chunks should reassemble cleanly,
    // proving frame 1's partial buffer was discarded rather than merged.
    expect(
      reassembler.accept(chunk({ frameID: 2, chunkIndex: 0, chunkCount: 2, data: new Uint8Array([9]) })),
    ).toBeNull();
    const result = reassembler.accept(
      chunk({ frameID: 2, chunkIndex: 1, chunkCount: 2, data: new Uint8Array([10]) }),
    );
    expect(result).not.toBeNull();
    expect(result!.annexB).toEqual(new Uint8Array([9, 10]));

    // Frame 1's leftover final chunk must not silently complete anything using stale state.
    const stray = reassembler.accept(
      chunk({ frameID: 1, chunkIndex: 2, chunkCount: 3, data: new Uint8Array([3]) }),
    );
    expect(stray).toBeNull();
  });
});
