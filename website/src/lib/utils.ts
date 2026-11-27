export function cn(...classes: Array<string | false | null | undefined>) {
  return classes.filter(Boolean).join(" ");
}

/**
 * Deterministic pseudo-random in [0, 1). Pure 32-bit integer math (no Math.sin),
 * so server and client produce bit-identical values and hydration matches.
 */
export function seeded(i: number) {
  let t = (i * 0x9e3779b9 + 0x6d2b79f5) | 0;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

/** Round for inline style strings so SSR and client markup stay identical. */
export const r3 = (n: number) => Math.round(n * 1000) / 1000;
