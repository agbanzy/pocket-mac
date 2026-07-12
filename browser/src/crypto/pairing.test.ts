// Conformance tests for the pairing URL parser — proves this port accepts exactly the
// `pocketmac://pair?...` URL shape the Mac helper generates (mirror of PairingPayload.swift),
// and that its base64url/hex helpers round-trip byte-for-byte with the Swift side.

import { describe, expect, it } from 'vitest';
import { base64urlDecode, base64urlEncode, bytesToHex, hexToBytes, parsePairingURL } from './pairing';

// Deterministic "arbitrary" bytes — no Math.random, so a failure reproduces exactly every run.
function fixedBytes(length: number, seed: number): Uint8Array {
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) out[i] = (seed + i * 31) & 0xff;
  return out;
}

describe('parsePairingURL', () => {
  it('parses a well-formed pocketmac:// pairing URL', () => {
    const macPublicKey = fixedBytes(32, 3);
    const rendezvousToken = fixedBytes(16, 41);
    const url =
      `pocketmac://pair?v=1&pk=${base64urlEncode(macPublicKey)}` +
      `&n=Guru%27s%20Mac&rt=${base64urlEncode(rendezvousToken)}&sas=123456`;

    const payload = parsePairingURL(url);

    expect(payload.version).toBe(1);
    expect(payload.deviceName).toBe("Guru's Mac");
    expect(payload.sas).toBe('123456');
    expect(payload.macPublicKey).toEqual(macPublicKey);
    expect(payload.macPublicKey.length).toBe(32);
    expect(payload.rendezvousToken).toEqual(rendezvousToken);
    expect(payload.rendezvousToken.length).toBe(16);
  });

  it('throws on the wrong URL scheme', () => {
    const url =
      `https://pair?v=1&pk=${base64urlEncode(fixedBytes(32, 1))}` +
      `&n=x&rt=${base64urlEncode(fixedBytes(16, 2))}&sas=123456`;
    expect(() => parsePairingURL(url)).toThrow();
  });

  it('throws when a required field is missing', () => {
    // rt (rendezvous token) omitted.
    const url = `pocketmac://pair?v=1&pk=${base64urlEncode(fixedBytes(32, 1))}&n=x&sas=123456`;
    expect(() => parsePairingURL(url)).toThrow();
  });

  it('throws when pk decodes to something other than 32 bytes', () => {
    const badKey = base64urlEncode(fixedBytes(16, 9)); // 16 bytes, not 32
    const url =
      `pocketmac://pair?v=1&pk=${badKey}&n=x&rt=${base64urlEncode(fixedBytes(16, 2))}&sas=123456`;
    expect(() => parsePairingURL(url)).toThrow();
  });
});

describe('base64url + hex round-trip', () => {
  const lengths = [0, 1, 2, 3, 4, 5, 15, 16, 32, 37];

  for (const length of lengths) {
    it(`base64url round-trips ${length} arbitrary bytes`, () => {
      const bytes = fixedBytes(length, length + 13);
      expect(base64urlDecode(base64urlEncode(bytes))).toEqual(bytes);
    });

    it(`hex round-trips ${length} arbitrary bytes`, () => {
      const bytes = fixedBytes(length, length + 29);
      expect(hexToBytes(bytesToHex(bytes))).toEqual(bytes);
    });
  }
});
