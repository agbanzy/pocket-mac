// Noise_IK_25519_ChaChaPoly_SHA256 — byte-for-byte mirror of:
//   shared/PocketMacKit/Sources/PocketMacKit/Crypto/Noise/NoisePrimitives.swift
//   shared/PocketMacKit/Sources/PocketMacKit/Crypto/Noise/NoiseHandshakeIK.swift
//
// The browser is always the INITIATOR (like the iOS app). It already knows the Mac's
// static public key from the pairing URL — exactly the IK premise. The responder role is
// implemented too, purely so the JS handshake can be unit-tested end-to-end (loopback).
//
// Two nonce conventions live here, and they differ deliberately:
//   * The handshake CipherState uses a Noise-spec nonce: 4 zero bytes ++ 8-byte LITTLE-endian counter.
//   * The post-handshake AEADChannel (aead.ts) uses salt(4) ++ 8-byte BIG-endian counter.
// Both are mirrored exactly from the Swift.

import { sha256 } from '@noble/hashes/sha256';
import { hmac } from '@noble/hashes/hmac';
import { concatBytes, utf8ToBytes } from '@noble/hashes/utils';
import { chacha20poly1305 } from '@noble/ciphers/chacha';
import { x25519 } from '@noble/curves/ed25519';

export const NOISE_PROTOCOL_NAME = 'Noise_IK_25519_ChaChaPoly_SHA256';

const hmacSha256 = (key: Uint8Array, data: Uint8Array): Uint8Array => hmac(sha256, key, data);
const dh = (priv: Uint8Array, pub: Uint8Array): Uint8Array => x25519.getSharedSecret(priv, pub);
const pub = (priv: Uint8Array): Uint8Array => x25519.getPublicKey(priv);

/**
 * Noise's HKDF: temp = HMAC(ck, ikm); out_i = HMAC(temp, out_{i-1} ‖ i).
 * Mirrors NoiseHKDF.derive — HKDF-Expand with the Noise-specified info bytes.
 */
export function noiseHKDF(chainingKey: Uint8Array, ikm: Uint8Array, outputs: 2 | 3): Uint8Array[] {
  const temp = hmacSha256(chainingKey, ikm);
  const o1 = hmacSha256(temp, Uint8Array.of(0x01));
  if (outputs === 2) {
    const o2 = hmacSha256(temp, concatBytes(o1, Uint8Array.of(0x02)));
    return [o1, o2];
  }
  const o2 = hmacSha256(temp, concatBytes(o1, Uint8Array.of(0x02)));
  const o3 = hmacSha256(temp, concatBytes(o2, Uint8Array.of(0x03)));
  return [o1, o2, o3];
}

/** The Noise CipherState nonce: 32 bits of zero followed by the 64-bit counter, little-endian. */
function noiseNonce(counter: bigint): Uint8Array {
  const nonce = new Uint8Array(12); // first 4 bytes zero
  const view = new DataView(nonce.buffer);
  view.setBigUint64(4, counter, true /* little-endian */);
  return nonce;
}

/** Noise CipherState: an AEAD key + 64-bit nonce. No key => data passes through as plaintext. */
class NoiseCipherState {
  private nonce = 0n;
  constructor(private readonly key: Uint8Array | null) {}

  encrypt(ad: Uint8Array, plaintext: Uint8Array): Uint8Array {
    if (!this.key) return plaintext;
    const ct = chacha20poly1305(this.key, noiseNonce(this.nonce), ad).encrypt(plaintext);
    this.nonce += 1n;
    return ct; // noble returns ciphertext ‖ 16-byte tag, matching CryptoKit's ct + tag
  }

  decrypt(ad: Uint8Array, ciphertext: Uint8Array): Uint8Array {
    if (!this.key) return ciphertext;
    const pt = chacha20poly1305(this.key, noiseNonce(this.nonce), ad).decrypt(ciphertext);
    this.nonce += 1n;
    return pt;
  }
}

/** Noise SymmetricState: chaining key + handshake hash + current cipher state. */
class NoiseSymmetricState {
  private cipher: NoiseCipherState;
  private chainingKey: Uint8Array;
  handshakeHash: Uint8Array;

  constructor(protocolName: string) {
    const name = utf8ToBytes(protocolName);
    if (name.length <= 32) {
      const h = new Uint8Array(32); // zero-padded; the IK name is exactly 32 bytes so no padding
      h.set(name);
      this.handshakeHash = h;
    } else {
      this.handshakeHash = sha256(name);
    }
    this.chainingKey = this.handshakeHash;
    this.cipher = new NoiseCipherState(null);
  }

  mixKey(input: Uint8Array): void {
    const [ck, k] = noiseHKDF(this.chainingKey, input, 2);
    this.chainingKey = ck;
    this.cipher = new NoiseCipherState(k);
  }

  mixHash(data: Uint8Array): void {
    this.handshakeHash = sha256(concatBytes(this.handshakeHash, data));
  }

  encryptAndHash(plaintext: Uint8Array): Uint8Array {
    const ct = this.cipher.encrypt(this.handshakeHash, plaintext);
    this.mixHash(ct);
    return ct;
  }

  decryptAndHash(ciphertext: Uint8Array): Uint8Array {
    const pt = this.cipher.decrypt(this.handshakeHash, ciphertext);
    this.mixHash(ciphertext);
    return pt;
  }

  /** Two directional transport keys. c1 is initiator->responder, c2 the reverse. */
  split(): { c1: Uint8Array; c2: Uint8Array } {
    const [c1, c2] = noiseHKDF(this.chainingKey, new Uint8Array(0), 2);
    return { c1, c2 };
  }
}

export type NoiseRole = 'initiator' | 'responder';

export interface SessionKeys {
  sendKey: Uint8Array; // 32 bytes
  recvKey: Uint8Array; // 32 bytes
  sendSalt: Uint8Array; // 4 bytes
  recvSalt: Uint8Array; // 4 bytes
  peerPublicKey: Uint8Array; // the authenticated remote static (32 bytes)
}

const ENC_STATIC_LENGTH = 48; // 32-byte key + 16-byte tag in message 1

/**
 * The Noise IK handshake state machine (no I/O), mirroring NoiseHandshakeIK.
 *   -> e, es, s, ss
 *   <- e, ee, se
 */
export class NoiseHandshakeIK {
  private sym: NoiseSymmetricState;
  private readonly sPriv: Uint8Array;
  private readonly sPub: Uint8Array;
  private ePriv: Uint8Array | null;
  private rs: Uint8Array | null; // remote static
  private re: Uint8Array | null = null; // remote ephemeral

  /**
   * @param remoteStatic  required for the initiator (the paired Mac's key); null for the responder.
   * @param prologue      bound into the transcript before any token. The app uses an EMPTY prologue.
   * @param ephemeral     injectable for deterministic tests; random in production.
   */
  constructor(
    readonly role: NoiseRole,
    localStaticPriv: Uint8Array,
    remoteStatic: Uint8Array | null,
    prologue: Uint8Array,
    ephemeral?: Uint8Array,
  ) {
    this.sPriv = localStaticPriv;
    this.sPub = pub(localStaticPriv);
    this.rs = remoteStatic ? Uint8Array.from(remoteStatic) : null;
    this.ePriv = ephemeral ?? null;

    const sym = new NoiseSymmetricState(NOISE_PROTOCOL_NAME);
    sym.mixHash(prologue);
    // Pre-message `<- s`: the responder's static public key, known to both sides.
    const responderStaticPub =
      role === 'initiator' ? (this.rs ?? new Uint8Array(0)) : this.sPub;
    sym.mixHash(responderStaticPub);
    this.sym = sym;
  }

  /** The authenticated remote static, once known. */
  get remoteStaticPublicKey(): Uint8Array | null {
    return this.rs;
  }

  // ---- Message 1 — initiator -> responder (e, es, s, ss) ----

  writeMessage1(payload: Uint8Array = new Uint8Array(0)): Uint8Array {
    if (this.role !== 'initiator') throw new Error('writeMessage1 requires initiator');
    if (!this.rs) throw new Error('initiator missing remote static');
    const ePriv = this.ePriv ?? x25519.utils.randomSecretKey();
    this.ePriv = ePriv;

    const ePub = pub(ePriv);
    const out: Uint8Array[] = [ePub];
    this.sym.mixHash(ePub); // e
    this.sym.mixKey(dh(ePriv, this.rs)); // es
    out.push(this.sym.encryptAndHash(this.sPub)); // s (encrypted static)
    this.sym.mixKey(dh(this.sPriv, this.rs)); // ss
    out.push(this.sym.encryptAndHash(payload)); // payload
    return concatBytes(...out);
  }

  readMessage1(data: Uint8Array): Uint8Array {
    if (this.role !== 'responder') throw new Error('readMessage1 requires responder');
    const ePub = data.subarray(0, 32);
    this.re = Uint8Array.from(ePub);
    this.sym.mixHash(ePub); // e
    this.sym.mixKey(dh(this.sPriv, this.re)); // es
    const encStatic = data.subarray(32, 32 + ENC_STATIC_LENGTH);
    const rsBytes = this.sym.decryptAndHash(encStatic); // s
    this.rs = Uint8Array.from(rsBytes);
    this.sym.mixKey(dh(this.sPriv, this.rs)); // ss
    return this.sym.decryptAndHash(data.subarray(32 + ENC_STATIC_LENGTH)); // payload
  }

  // ---- Message 2 — responder -> initiator (e, ee, se) ----

  writeMessage2(payload: Uint8Array = new Uint8Array(0)): Uint8Array {
    if (this.role !== 'responder') throw new Error('writeMessage2 requires responder');
    if (!this.re || !this.rs) throw new Error('responder missing remote keys');
    const ePriv = this.ePriv ?? x25519.utils.randomSecretKey();
    this.ePriv = ePriv;

    const ePub = pub(ePriv);
    const out: Uint8Array[] = [ePub];
    this.sym.mixHash(ePub); // e
    this.sym.mixKey(dh(ePriv, this.re)); // ee
    this.sym.mixKey(dh(ePriv, this.rs)); // se (responder ephemeral <-> initiator static)
    out.push(this.sym.encryptAndHash(payload)); // payload
    return concatBytes(...out);
  }

  readMessage2(data: Uint8Array): Uint8Array {
    if (this.role !== 'initiator') throw new Error('readMessage2 requires initiator');
    if (!this.ePriv) throw new Error('initiator missing ephemeral');
    const ePub = data.subarray(0, 32);
    this.re = Uint8Array.from(ePub);
    this.sym.mixHash(ePub); // e
    this.sym.mixKey(dh(this.ePriv, this.re)); // ee
    this.sym.mixKey(dh(this.sPriv, this.re)); // se (initiator static <-> responder ephemeral)
    return this.sym.decryptAndHash(data.subarray(32)); // payload
  }

  // ---- Completion ----

  /**
   * Derives directional session keys. Both sides mirror. Directional 4-byte salts are split from the
   * final transcript hash (identical on both ends). Mirror of NoiseHandshakeIK.makeSessionKeys.
   */
  makeSessionKeys(): SessionKeys {
    if (!this.rs) throw new Error('no authenticated remote static');
    const { c1, c2 } = this.sym.split();
    const saltA = this.sym.handshakeHash.subarray(0, 4);
    const saltB = this.sym.handshakeHash.subarray(4, 8);
    if (this.role === 'initiator') {
      return {
        sendKey: c1,
        recvKey: c2,
        sendSalt: Uint8Array.from(saltA),
        recvSalt: Uint8Array.from(saltB),
        peerPublicKey: this.rs,
      };
    }
    return {
      sendKey: c2,
      recvKey: c1,
      sendSalt: Uint8Array.from(saltB),
      recvSalt: Uint8Array.from(saltA),
      peerPublicKey: this.rs,
    };
  }
}
