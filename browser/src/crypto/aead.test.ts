// Conformance tests for the post-handshake AEAD record layer — proves this port matches
// aead.ts's mirrored contract: [u64 counter, BIG-endian][ciphertext…][16-byte tag], distinct
// send/recv keys+salts per direction, and a strictly-increasing receive counter (replay policy).
// See aead.ts's header for the mirrored Swift sources.

import { describe, expect, it } from 'vitest';
import { AEADChannel } from './aead';
import { SessionKeys } from './noise';

// Deterministic "arbitrary" bytes — no Math.random, so a failure reproduces exactly every run.
function fixedBytes(length: number, seed: number): Uint8Array {
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) out[i] = (seed + i * 31) & 0xff;
  return out;
}

/**
 * Hand-constructs a loopback pair of channels: A's send key/salt equal B's recv key/salt and
 * vice versa — exactly the relationship two ends of one real Noise handshake derive (see
 * noise.test.ts for that full derivation). Doing it by hand here isolates the AEAD record layer
 * from the handshake, per the Story's test plan.
 */
function makeChannelPair(): { a: AEADChannel; b: AEADChannel } {
  const keyAtoB = fixedBytes(32, 11);
  const keyBtoA = fixedBytes(32, 222);
  const saltAtoB = fixedBytes(4, 5);
  const saltBtoA = fixedBytes(4, 99);

  const keysA: SessionKeys = {
    sendKey: keyAtoB,
    recvKey: keyBtoA,
    sendSalt: saltAtoB,
    recvSalt: saltBtoA,
    peerPublicKey: fixedBytes(32, 1),
  };
  const keysB: SessionKeys = {
    sendKey: keyBtoA,
    recvKey: keyAtoB,
    sendSalt: saltBtoA,
    recvSalt: saltAtoB,
    peerPublicKey: fixedBytes(32, 2),
  };

  return { a: new AEADChannel(keysA), b: new AEADChannel(keysB) };
}

/** The 8-byte big-endian counter prefix a record should carry at a given send index. */
function counterBytes(counter: number): Uint8Array {
  const bytes = new Uint8Array(8);
  bytes[7] = counter;
  return bytes;
}

describe('AEADChannel', () => {
  it('seals on one side and opens to the identical plaintext on the other', () => {
    const { a, b } = makeChannelPair();
    const plaintexts = [
      new TextEncoder().encode('hello pocket mac'),
      new Uint8Array([0, 1, 2, 3, 254, 255]),
      new TextEncoder().encode(''),
    ];
    for (const pt of plaintexts) {
      expect(b.open(a.seal(pt))).toEqual(pt);
    }
  });

  it('increments the big-endian record counter 0, 1, 2 across successive seals', () => {
    const { a } = makeChannelPair();
    const pt = new TextEncoder().encode('frame');
    const r0 = a.seal(pt);
    const r1 = a.seal(pt);
    const r2 = a.seal(pt);
    expect(r0.slice(0, 8)).toEqual(counterBytes(0));
    expect(r1.slice(0, 8)).toEqual(counterBytes(1));
    expect(r2.slice(0, 8)).toEqual(counterBytes(2));
  });

  it('rejects replaying the same record twice', () => {
    const { a, b } = makeChannelPair();
    const record = a.seal(new TextEncoder().encode('one-time'));
    expect(b.open(record)).toEqual(new TextEncoder().encode('one-time'));
    expect(() => b.open(record)).toThrow();
  });

  it('rejects a record with one tampered ciphertext byte', () => {
    const { a, b } = makeChannelPair();
    const record = a.seal(new TextEncoder().encode('integrity check'));
    const tampered = Uint8Array.from(record);
    tampered[8] ^= 0xff; // first ciphertext byte, just past the 8-byte counter prefix
    expect(() => b.open(tampered)).toThrow();
  });
});
