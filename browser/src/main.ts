// App entry: wires identity + pairing + the relay session + the H.264 decoder + input capture into
// the two-view UI (pair screen ↔ live screen). The browser mirror of ios/PocketMac's RootView/RemoteView.

import './styles.css';
import { Connection, ConnState } from './session/connection';
import { attachInput } from './input/controls';
import { ScreenDecoder } from './video/decoder';
import { loadOrCreateIdentity, resetIdentity, peerFingerprint } from './crypto/identity';
import { savePairing, loadPairing, clearPairing } from './crypto/identity';
import { parsePairingURL, PairingPayload } from './crypto/pairing';

const DEFAULT_RELAY = 'wss://165.227.155.134.sslip.io/ws';
const RELAY_KEY = 'pocketmac.relay';

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`missing #${id}`);
  return el as T;
};

const pairingView = $('pairing');
const stageView = $('stage');
const pairInput = $<HTMLTextAreaElement>('pair-input');
const relayInput = $<HTMLInputElement>('relay-input');
const pairErr = $('pair-error');
const pairBtn = $<HTMLButtonElement>('pair-btn');
const resetBtn = $<HTMLButtonElement>('reset-btn');
const fingerprintEl = $('fingerprint');
const canvas = $<HTMLCanvasElement>('screen');
const dot = $('dot');
const peerEl = $('peer');
const latencyEl = $('latency');
const hint = $('hint');
const fsBtn = $<HTMLButtonElement>('fs-btn');
const disconnectBtn = $<HTMLButtonElement>('disconnect-btn');

const identity = loadOrCreateIdentity();
fingerprintEl.textContent = peerFingerprint(identity.publicKey);

relayInput.value = localStorage.getItem(RELAY_KEY) ?? DEFAULT_RELAY;

// If we've paired before, offer a one-click reconnect without re-pasting.
const saved = loadPairing();
if (saved) pairBtn.textContent = `Connect to ${saved.deviceName}`;

let conn: Connection | null = null;
let decoder: ScreenDecoder | null = null;
let detachInput: (() => void) | null = null;
let peerName = saved?.deviceName ?? 'Mac';

function setError(msg: string): void {
  pairErr.textContent = msg;
  pairErr.hidden = false;
}
function clearError(): void {
  pairErr.hidden = true;
}

function showPairing(): void {
  stageView.hidden = true;
  pairingView.hidden = false;
}
function showStage(): void {
  pairingView.hidden = true;
  stageView.hidden = false;
}

function handleState(state: ConnState): void {
  dot.className = 'dot ' + state.t;
  if (state.t === 'connecting') {
    showStage();
    peerEl.textContent = `${peerName} · connecting…`;
    latencyEl.textContent = '';
  } else if (state.t === 'secured') {
    showStage();
    peerEl.textContent = peerName;
    if (!detachInput) detachInput = attachInput(canvas, (i) => conn?.sendInput(i));
    canvas.focus();
    flashHint();
  } else {
    // idle or offline → tear down input/decoder and return to the pairing screen.
    detachInput?.();
    detachInput = null;
    decoder?.close();
    decoder = null;
    showPairing();
    if (state.t === 'offline') setError(state.reason);
  }
}

async function connectWith(payload: PairingPayload): Promise<void> {
  const relayURL = relayInput.value.trim() || DEFAULT_RELAY;
  localStorage.setItem(RELAY_KEY, relayURL);
  peerName = payload.deviceName || 'Mac';

  detachInput?.();
  detachInput = null;
  decoder?.close();
  decoder = new ScreenDecoder(canvas, (e) => setError(e.message));

  conn?.disconnect();
  conn = new Connection(relayURL, {
    onState: handleState,
    onLatency: (ms) => (latencyEl.textContent = ms == null ? '' : `${ms} ms`),
    onVideoFrame: (f) => decoder?.push(f),
  });
  await conn.connect(payload, identity);
}

function flashHint(): void {
  hint.classList.remove('fade');
  window.setTimeout(() => hint.classList.add('fade'), 4000);
}

pairBtn.addEventListener('click', () => {
  clearError();
  const raw = pairInput.value.trim();
  let payload: PairingPayload;
  try {
    if (raw) {
      payload = parsePairingURL(raw);
      savePairing(payload);
    } else {
      const stored = loadPairing();
      if (!stored) throw new Error('Paste the pairing link your Mac shows.');
      payload = stored;
    }
  } catch (e) {
    setError(e instanceof Error ? e.message : 'Invalid pairing link');
    return;
  }
  void connectWith(payload);
});

resetBtn.addEventListener('click', () => {
  resetIdentity();
  clearPairing();
  location.reload();
});

disconnectBtn.addEventListener('click', () => conn?.disconnect());

fsBtn.addEventListener('click', () => {
  if (document.fullscreenElement) void document.exitFullscreen();
  else void stageView.requestFullscreen().catch(() => {});
});

// Support a deep link / query: ?pair=<url-encoded pocketmac://…> and ?relay=<wss…> for shareable setup.
const params = new URLSearchParams(location.search);
const relayParam = params.get('relay');
if (relayParam) relayInput.value = relayParam;
const pairParam = params.get('pair');
if (pairParam) pairInput.value = pairParam;
