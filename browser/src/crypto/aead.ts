// The per-frame record layer — byte-for-byte mirror of:
//   shared/PocketMacKit/Sources/PocketMacKit/Crypto/AEADChannel.swift
//   shared/PocketMacKit/Sources/PocketMacKit/Crypto/ReplayWindow.swift
//
// Wire record layout:
//   [u64 counter, BIG-endian][ciphertext…][16-byte Poly1305 tag]
// The 12-byte nonce is salt(4) ‖ counter(8, big-endian) and is never transmitted. Send and receive
// use distinct keys and salts, so the two directions share no nonce space. Receive enforces a
// strictly-increasing counter (Milestone-0 ReplayWindow policy).
//
// NOTE the deliberate contrast with the handshake CipherState in noise.ts: that uses a LITTLE-endian
// counter (Noise spec); this record layer uses a BIG-endian counter (the app's own layer).

import { chacha20poly1305 } from '@noble/ciphers/chacha';
import { SessionKeys } from './noise';

const TAG_LENGTH = 16;
const COUNTER_LENGTH = 8;

/** Rejects replayed/reordered records by a strictly-increasing counter (ordered transport). */
class ReplayWindow {
  private highestSeen: bigint | null = null;
  validate(counter: bigint): void {
    if (this.highestSeen !== null && counter <= this.highestSeen) {
      throw new Error(`replay detected: counter ${counter}`);
    }
    this.highestSeen = counter;
  }
}

function nonceData(salt: Uint8Array, counter: bigint): Uint8Array {
  const nonce = new Uint8Array(12);
  nonce.set(salt.subarray(0, 4), 0);
  new DataView(nonce.buffer).setBigUint64(4, counter, false /* big-endian */);
  return nonce;
}

function counterBytes(counter: bigint): Uint8Array {
  const bytes = new Uint8Array(COUNTER_LENGTH);
  new DataView(bytes.buffer).setBigUint64(0, counter, false /* big-endian */);
  return bytes;
}

function readCounter(bytes: Uint8Array): bigint {
  return new DataView(bytes.buffer, bytes.byteOffset, COUNTER_LENGTH).getBigUint64(0, false);
}

/** ChaCha20-Poly1305 AEAD under a 64-bit monotonic counter nonce, with replay rejection. */
export class AEADChannel {
  readonly peerPublicKey: Uint8Array;
  private readonly sendKey: Uint8Array;
  private readonly recvKey: Uint8Array;
  private readonly sendSalt: Uint8Array;
  private readonly recvSalt: Uint8Array;
  private sendCounter = 0n;
  private replay = new ReplayWindow();

  constructor(keys: SessionKeys) {
    this.peerPublicKey = keys.peerPublicKey;
    this.sendKey = keys.sendKey;
    this.recvKey = keys.recvKey;
    this.sendSalt = keys.sendSalt;
    this.recvSalt = keys.recvSalt;
  }

  /** Seals a plaintext frame record into a wire record (counter ‖ ciphertext ‖ tag). */
  seal(plaintext: Uint8Array): Uint8Array {
    if (this.sendCounter === 0xffffffffffffffffn) throw new Error('nonce exhausted');
    const counter = this.sendCounter;
    const nonce = nonceData(this.sendSalt, counter);
    // noble returns ciphertext ‖ tag; CryptoKit appends box.ciphertext + box.tag — identical layout.
    const ctTag = chacha20poly1305(this.sendKey, nonce).encrypt(plaintext);
    const record = new Uint8Array(COUNTER_LENGTH + ctTag.length);
    record.set(counterBytes(counter), 0);
    record.set(ctTag, COUNTER_LENGTH);
    this.sendCounter += 1n;
    return record;
  }

  /** Opens a wire record back into plaintext, rejecting replays and tampering. */
  open(record: Uint8Array): Uint8Array {
    if (record.length < COUNTER_LENGTH + TAG_LENGTH) throw new Error('malformed record');
    const counter = readCounter(record);
    // Replay check BEFORE the AEAD open so a flood of replays is cheap to reject.
    this.replay.validate(counter);
    const ctTag = record.subarray(COUNTER_LENGTH); // ciphertext ‖ tag
    const nonce = nonceData(this.recvSalt, counter);
    return chacha20poly1305(this.recvKey, nonce).decrypt(ctTag);
  }
}
