// Parses the `pocketmac://pair?…` URL the Mac helper shows. Mirror of:
//   shared/PocketMacKit/Sources/PocketMacKit/Crypto/PairingPayload.swift
//
// URL form: pocketmac://pair?v=<u8>&pk=<base64url 32-byte X25519>&n=<name>&rt=<base64url token>&sas=<6 digits>
// The relay HELLO token is rt decoded to bytes then hex-encoded (see transport/relay.ts).

export interface PairingPayload {
  version: number;
  macPublicKey: Uint8Array; // raw 32-byte X25519 (rs — the responder static)
  deviceName: string;
  rendezvousToken: Uint8Array; // 16 bytes, for the relay path
  sas: string; // 6 digits
}

/** URL-safe base64 without padding: +/ -> -_, = stripped. Mirror of Base64URL in Swift. */
export function base64urlDecode(input: string): Uint8Array {
  let s = input.replace(/-/g, '+').replace(/_/g, '/');
  const remainder = s.length % 4;
  if (remainder > 0) s += '='.repeat(4 - remainder);
  const binary = atob(s);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function base64urlEncode(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Lowercase hex encoding — the relay hex-decodes the HELLO token. Mirror of Data.hexEncodedString. */
export function bytesToHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) out += bytes[i].toString(16).padStart(2, '0');
  return out;
}

export function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim().toLowerCase();
  if (clean.length % 2 !== 0) throw new Error('odd-length hex');
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(clean.substr(i * 2, 2), 16);
  return bytes;
}

/**
 * Parse a `pocketmac://pair?…` URL. The scheme `pocketmac://pair?…` puts `pair` in the host and the
 * fields in the query string — parsed here without relying on the URL API's scheme handling.
 */
export function parsePairingURL(urlString: string): PairingPayload {
  const trimmed = urlString.trim();
  const match = /^pocketmac:\/\/pair\?(.*)$/i.exec(trimmed);
  if (!match) throw new Error('not a pocketmac pairing URL');
  const params = new URLSearchParams(match[1]);

  const vStr = params.get('v');
  const pkStr = params.get('pk');
  const name = params.get('n');
  const rtStr = params.get('rt');
  const sas = params.get('sas');
  if (vStr === null || pkStr === null || name === null || rtStr === null || sas === null) {
    throw new Error('pairing URL missing fields');
  }
  const version = Number(vStr);
  if (!Number.isInteger(version) || version < 0 || version > 255) throw new Error('bad version');
  const macPublicKey = base64urlDecode(pkStr);
  if (macPublicKey.length !== 32) throw new Error('pk must decode to 32 bytes');
  const rendezvousToken = base64urlDecode(rtStr);
  if (rendezvousToken.length < 16) throw new Error('rt too short');

  return { version, macPublicKey, deviceName: name, rendezvousToken, sas };
}
