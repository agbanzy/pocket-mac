// Protocol conformance: this port must match shared/conformance/vectors.json exactly.
//
// The Swift PocketMacKit implementation is the reference, but the *contract* lives in the vectors
// file so no port is privileged. Adding an opcode to the protocol without updating this port makes
// these tests fail — which is exactly how the AI-task opcodes (runTask/taskEvent/stopTask/
// pinResponse) were caught missing here after they shipped on Swift.

import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { ControlOpcode, FrameDomain, InputOpcode, MouseButton } from './frames';
import { TaskEventKind } from './frames';

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(
  readFileSync(resolve(here, '../../../shared/conformance/vectors.json'), 'utf8'),
) as { enums: Record<string, Record<string, number>> };

/** TS numeric enums are bidirectional maps; keep only the name → value half, lowercased. */
function tableOf(e: object): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(e)) {
    if (typeof v === 'number') out[k.charAt(0).toLowerCase() + k.slice(1)] = v;
  }
  return out;
}

const cases: Array<[string, object]> = [
  ['FrameDomain', FrameDomain],
  ['ControlOpcode', ControlOpcode],
  ['InputOpcode', InputOpcode],
  ['TaskEventKind', TaskEventKind],
  ['MouseButton', MouseButton],
];

describe('wire protocol conformance', () => {
  for (const [name, e] of cases) {
    it(`${name} matches the canonical vectors`, () => {
      const expected = vectors.enums[name];
      expect(expected, `vectors.json has no ${name}`).toBeDefined();
      // Compare whole tables: catches BOTH a missing case and a wrong/extra value.
      expect(tableOf(e)).toEqual(expected);
    });
  }

  it('every control opcode is contiguous from 0 (no gaps that would desync a peer)', () => {
    const values = Object.values(vectors.enums.ControlOpcode).sort((a, b) => a - b);
    expect(values).toEqual(values.map((_, i) => i));
  });
});
