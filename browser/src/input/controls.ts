// Translates DOM pointer/keyboard/wheel events on the screen canvas into wire InputFrames.
// Pointer position maps to the Mac's normalized absolute space (0…65535 across the main display),
// matching mac/PocketMacHelper/Input/CGEventTranslator.swift `moveAbsolute`. Typed text goes as
// `unicodeText` (browser applies shift/caps for us); shortcuts and navigation keys go as keyDown/keyUp
// with macOS virtual keycodes and modifier flags — the same split the iOS HiddenKeyboardField uses.

import { InputFrame, Modifier, MouseButton } from '../protocol/frames';

const ABS_MAX = 65535;
const INT16_MAX = 32767;
const INT16_MIN = -32768;
// Wheel sign: flip once here if QA shows scrolling is inverted on the Mac.
const WHEEL_SIGN = -1;

/** KeyboardEvent.code → macOS virtual keycode (ANSI US, layout-independent physical keys). */
const KEYCODES: Record<string, number> = {
  KeyA: 0, KeyS: 1, KeyD: 2, KeyF: 3, KeyH: 4, KeyG: 5, KeyZ: 6, KeyX: 7, KeyC: 8, KeyV: 9,
  KeyB: 11, KeyQ: 12, KeyW: 13, KeyE: 14, KeyR: 15, KeyY: 16, KeyT: 17, KeyO: 31, KeyU: 32,
  KeyI: 34, KeyP: 35, KeyL: 37, KeyJ: 38, KeyK: 40, KeyN: 45, KeyM: 46,
  Digit1: 18, Digit2: 19, Digit3: 20, Digit4: 21, Digit6: 22, Digit5: 23, Digit9: 25, Digit7: 26,
  Digit8: 28, Digit0: 29, Equal: 24, Minus: 27, BracketRight: 30, BracketLeft: 33, Quote: 39,
  Semicolon: 41, Backslash: 42, Comma: 43, Slash: 44, Period: 47, Backquote: 50,
  Return: 36, Enter: 36, Tab: 48, Space: 49, Backspace: 51, Escape: 53,
  ArrowLeft: 123, ArrowRight: 124, ArrowDown: 125, ArrowUp: 126,
  Delete: 117, ForwardDelete: 117, Home: 115, End: 119, PageUp: 116, PageDown: 121,
};

// Keys we forward as keycodes even with no modifier (navigation / editing, not printable text).
const NAV_KEYS = new Set([
  'Return', 'Enter', 'Tab', 'Backspace', 'Escape', 'Delete',
  'ArrowLeft', 'ArrowRight', 'ArrowDown', 'ArrowUp', 'Home', 'End', 'PageUp', 'PageDown',
]);

function clampInt16(v: number): number {
  return Math.max(INT16_MIN, Math.min(INT16_MAX, Math.round(v)));
}

function modifierFlags(e: KeyboardEvent): number {
  let m = 0;
  if (e.shiftKey) m |= Modifier.Shift;
  if (e.ctrlKey) m |= Modifier.Control;
  if (e.altKey) m |= Modifier.Option;
  if (e.metaKey) m |= Modifier.Command;
  return m;
}

function buttonOf(e: PointerEvent | MouseEvent): MouseButton {
  return e.button === 2 ? MouseButton.Right : e.button === 1 ? MouseButton.Middle : MouseButton.Left;
}

/**
 * Wires input on `canvas`, sending frames via `send`. Returns a detach function.
 * The caller owns focus/visibility; we make the canvas focusable so it receives key events.
 */
export function attachInput(canvas: HTMLCanvasElement, send: (i: InputFrame) => void): () => void {
  canvas.tabIndex = 0; // focusable so keydown lands here
  canvas.style.touchAction = 'none';
  canvas.style.cursor = 'none';

  // --- pointer position, rAF-throttled so a fast mouse can't flood the channel ---
  let pending: { x: number; y: number } | null = null;
  let rafId = 0;
  const flush = () => {
    rafId = 0;
    if (pending) {
      send({ t: 'mouseMoveAbsolute', x: pending.x, y: pending.y });
      pending = null;
    }
  };
  const toAbsolute = (e: PointerEvent | MouseEvent): { x: number; y: number } => {
    const r = canvas.getBoundingClientRect();
    const nx = r.width > 0 ? (e.clientX - r.left) / r.width : 0;
    const ny = r.height > 0 ? (e.clientY - r.top) / r.height : 0;
    return {
      x: Math.max(0, Math.min(ABS_MAX, Math.round(nx * ABS_MAX))),
      y: Math.max(0, Math.min(ABS_MAX, Math.round(ny * ABS_MAX))),
    };
  };
  const queueMove = (e: PointerEvent) => {
    pending = toAbsolute(e);
    if (!rafId) rafId = requestAnimationFrame(flush);
  };

  const onPointerDown = (e: PointerEvent) => {
    e.preventDefault();
    canvas.focus();
    canvas.setPointerCapture(e.pointerId);
    const p = toAbsolute(e);
    send({ t: 'mouseMoveAbsolute', x: p.x, y: p.y }); // land the cursor before the press
    send({ t: 'mouseDown', button: buttonOf(e) });
  };
  const onPointerUp = (e: PointerEvent) => {
    e.preventDefault();
    if (canvas.hasPointerCapture(e.pointerId)) canvas.releasePointerCapture(e.pointerId);
    send({ t: 'mouseUp', button: buttonOf(e) });
  };
  const onContextMenu = (e: Event) => e.preventDefault(); // right-click is a Mac right-button, not a menu

  const onWheel = (e: WheelEvent) => {
    e.preventDefault();
    const scale = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 800 : 1; // lines / pages → pixels
    const dx = clampInt16(WHEEL_SIGN * e.deltaX * scale);
    const dy = clampInt16(WHEEL_SIGN * e.deltaY * scale);
    if (dx !== 0 || dy !== 0) send({ t: 'scroll', dx, dy });
  };

  const onKeyDown = (e: KeyboardEvent) => {
    const mods = modifierFlags(e);
    const code = KEYCODES[e.code];

    // A shortcut (Cmd/Ctrl/Alt held) → forward the keycode + modifiers so the Mac runs the combo.
    if ((e.metaKey || e.ctrlKey || e.altKey) && code !== undefined) {
      e.preventDefault();
      send({ t: 'keyDown', keyCode: code, modifiers: mods });
      send({ t: 'keyUp', keyCode: code, modifiers: mods });
      return;
    }
    // Navigation / editing keys → keycode.
    if (NAV_KEYS.has(e.code) && code !== undefined) {
      e.preventDefault();
      send({ t: 'keyDown', keyCode: code, modifiers: mods });
      send({ t: 'keyUp', keyCode: code, modifiers: mods });
      return;
    }
    // Printable text → unicodeText (the browser has already applied shift/caps/dead-keys).
    if (e.key.length === 1) {
      e.preventDefault();
      send({ t: 'unicodeText', text: e.key });
    }
  };

  const opts: AddEventListenerOptions = { passive: false };
  canvas.addEventListener('pointermove', queueMove, opts);
  canvas.addEventListener('pointerdown', onPointerDown, opts);
  canvas.addEventListener('pointerup', onPointerUp, opts);
  canvas.addEventListener('contextmenu', onContextMenu);
  canvas.addEventListener('wheel', onWheel, opts);
  canvas.addEventListener('keydown', onKeyDown, opts);

  return () => {
    if (rafId) cancelAnimationFrame(rafId);
    canvas.removeEventListener('pointermove', queueMove, opts);
    canvas.removeEventListener('pointerdown', onPointerDown, opts);
    canvas.removeEventListener('pointerup', onPointerUp, opts);
    canvas.removeEventListener('contextmenu', onContextMenu);
    canvas.removeEventListener('wheel', onWheel, opts);
    canvas.removeEventListener('keydown', onKeyDown, opts);
    canvas.style.cursor = '';
  };
}
