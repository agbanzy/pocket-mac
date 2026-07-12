// This browser's long-term X25519 identity, and the paired Mac payload — persisted in localStorage
// so the browser stays the SAME paired peer across reloads.
//
// The Mac authorizes a connecting peer by its static public key (see
// mac/PocketMacHelper/App/HelperModel.swift + Server/SessionAccepter.swift). A fresh identity is only
// admitted during the Mac's pairing window (single-admission gate); after that the Mac remembers this
// public key and re-admits it on reconnect. So the private key MUST persist, or every reload would
// look like a new, unpaired device.
//
// SECURITY NOTE: localStorage is readable by any script on this origin. This mirrors the security
// posture of the iOS app's on-device keychain only loosely — a browser has no secure enclave. Treat
// the machine/browser profile running this client as trusted. The relay never sees the key; end-to-end
// encryption is unaffected. To reset the identity, use the "Reset identity" control (clears storage).

import { x25519 } from '@noble/curves/ed25519';
import { sha256 } from '@noble/hashes/sha256';
import { base64urlDecode, base64urlEncode, PairingPayload } from './pairing';

const PRIV_KEY = 'pocketmac.identity.priv';
const PAIR_KEY = 'pocketmac.pairing';

export interface BrowserIdentity {
  privateKey: Uint8Array; // 32-byte X25519 scalar
  publicKey: Uint8Array; // 32-byte X25519 u-coordinate
}

/** Loads the persisted identity, or generates + persists a fresh one. */
export function loadOrCreateIdentity(): BrowserIdentity {
  const stored = localStorage.getItem(PRIV_KEY);
  if (stored) {
    try {
      const privateKey = base64urlDecode(stored);
      if (privateKey.length === 32) {
        return { privateKey, publicKey: x25519.getPublicKey(privateKey) };
      }
    } catch {
      /* fall through to regenerate */
    }
  }
  const privateKey = x25519.utils.randomSecretKey();
  localStorage.setItem(PRIV_KEY, base64urlEncode(privateKey));
  return { privateKey, publicKey: x25519.getPublicKey(privateKey) };
}

export function resetIdentity(): void {
  localStorage.removeItem(PRIV_KEY);
}

/** The stable fingerprint the Mac would show for this peer: first 8 bytes of SHA256(pubkey), hex. */
export function peerFingerprint(publicKey: Uint8Array): string {
  const digest = sha256(publicKey);
  let out = '';
  for (let i = 0; i < 8; i++) out += digest[i].toString(16).padStart(2, '0').toUpperCase();
  return out;
}

// ---- Paired Mac payload persistence (so reconnect needs no re-paste) ----

interface StoredPairing {
  version: number;
  pk: string; // base64url
  n: string;
  rt: string; // base64url
  sas: string;
}

export function savePairing(p: PairingPayload): void {
  const stored: StoredPairing = {
    version: p.version,
    pk: base64urlEncode(p.macPublicKey),
    n: p.deviceName,
    rt: base64urlEncode(p.rendezvousToken),
    sas: p.sas,
  };
  localStorage.setItem(PAIR_KEY, JSON.stringify(stored));
}

export function loadPairing(): PairingPayload | null {
  const raw = localStorage.getItem(PAIR_KEY);
  if (!raw) return null;
  try {
    const s = JSON.parse(raw) as StoredPairing;
    return {
      version: s.version,
      macPublicKey: base64urlDecode(s.pk),
      deviceName: s.n,
      rendezvousToken: base64urlDecode(s.rt),
      sas: s.sas,
    };
  } catch {
    return null;
  }
}

export function clearPairing(): void {
  localStorage.removeItem(PAIR_KEY);
}
