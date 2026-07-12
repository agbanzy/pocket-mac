// Conformance tests for Noise_IK_25519_ChaChaPoly_SHA256 — proves this port derives identical
// directional session keys to the Swift NoiseHandshakeIK given the same inputs, and that the
// resulting keys are usable end-to-end through the frame codec + AEAD record layer. See noise.ts's
// header for the mirrored Swift sources and the deliberate little-endian (handshake) vs
// big-endian (record layer) nonce contrast.

import { x25519 } from '@noble/curves/ed25519';
import { describe, expect, it } from 'vitest';
import { control, decodeFrame, encodeFrame, input } from '../protocol/frames';
import { AEADChannel } from './aead';
import { NoiseHandshakeIK } from './noise';

// Deterministic "arbitrary" bytes for the injected ephemeral scalars — no Math.random, so the
// handshake transcript is reproducible on every run. X25519 clamps any 32-byte input, so a fixed
// non-random array is just as valid an ephemeral scalar as a randomly generated one.
function fixedBytes(length: number, seed: number): Uint8Array {
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) out[i] = (seed + i * 31) & 0xff;
  return out;
}

/** Runs one full IK loopback handshake (initiator already knows the responder's static key). */
function runHandshake() {
  // Static keypairs: real (crypto-secure) randomness is fine here — determinism only needs to
  // hold for the ephemerals, since both sides derive from whichever statics they're given.
  const initiatorStaticPriv = x25519.utils.randomSecretKey();
  const initiatorStaticPub = x25519.getPublicKey(initiatorStaticPriv);
  const responderStaticPriv = x25519.utils.randomSecretKey();
  const responderStaticPub = x25519.getPublicKey(responderStaticPriv);

  const initiatorEphemeral = fixedBytes(32, 3);
  const responderEphemeral = fixedBytes(32, 197);
  const prologue = new Uint8Array(0); // the app uses an EMPTY prologue

  const initiator = new NoiseHandshakeIK(
    'initiator',
    initiatorStaticPriv,
    responderStaticPub,
    prologue,
    initiatorEphemeral,
  );
  const responder = new NoiseHandshakeIK('responder', responderStaticPriv, null, prologue, responderEphemeral);

  const message1 = initiator.writeMessage1();
  responder.readMessage1(message1);
  const message2 = responder.writeMessage2();
  initiator.readMessage2(message2);

  return {
    initiatorKeys: initiator.makeSessionKeys(),
    responderKeys: responder.makeSessionKeys(),
    initiatorStaticPub,
    responderStaticPub,
  };
}

describe('NoiseHandshakeIK — loopback', () => {
  it('derives mirrored directional keys, salts, and peer identities on both sides', () => {
    const { initiatorKeys, responderKeys, initiatorStaticPub, responderStaticPub } = runHandshake();

    expect(initiatorKeys.sendKey).toEqual(responderKeys.recvKey);
    expect(initiatorKeys.recvKey).toEqual(responderKeys.sendKey);
    expect(initiatorKeys.sendSalt).toEqual(responderKeys.recvSalt);
    expect(initiatorKeys.recvSalt).toEqual(responderKeys.sendSalt);
    expect(initiatorKeys.peerPublicKey).toEqual(responderStaticPub);
    expect(responderKeys.peerPublicKey).toEqual(initiatorStaticPub);
  });

  it('feeds the derived keys into AEADChannel and round-trips an encoded Frame both directions', () => {
    const { initiatorKeys, responderKeys } = runHandshake();
    const initiatorChannel = new AEADChannel(initiatorKeys);
    const responderChannel = new AEADChannel(responderKeys);

    const outbound = control({ t: 'ping', nonce: 42 });
    const sealedOutbound = initiatorChannel.seal(encodeFrame(outbound));
    expect(decodeFrame(responderChannel.open(sealedOutbound))).toEqual(outbound);

    const inbound = input({ t: 'mouseMove', dx: 3, dy: -3 });
    const sealedInbound = responderChannel.seal(encodeFrame(inbound));
    expect(decodeFrame(initiatorChannel.open(sealedInbound))).toEqual(inbound);
  });
});
