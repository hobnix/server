// Bayer matrices for ordered dithering, built by the standard recursive doubling. bayerMatrix(n) is a Float32Array of n*n thresholds,
// index y * n + x, each strictly between 0 and 1 ((rank + 0.5) / n^2), every rank used exactly once. A cell is lit when the value at it is above
// its threshold. n must be a power of two (2, 4, 8, 16, 32): the doubling only exists for those, a size in between (12, say) has no Bayer matrix,
// so the settings offer 8 and 16 only. BAYER is the 8x8 one, shared by Halftone.svelte and Spark.svelte.
export const MATRIX_SIZES = [8, 16];

const cache = new Map();
export function bayerMatrix(n) {
  if (!Number.isInteger(n) || n < 2 || (n & (n - 1)) !== 0) throw new Error(`Bayer size must be a power of two, got ${n}`);
  if (cache.has(n)) return cache.get(n);
  let m = [[0, 2], [3, 1]];
  for (let s = 2; s < n; s *= 2) {
    const next = Array.from({ length: s * 2 }, () => new Array(s * 2));
    for (let y = 0; y < s; y++) for (let x = 0; x < s; x++) {
      const v = m[y][x] * 4;
      next[y][x] = v; next[y][x + s] = v + 2; next[y + s][x] = v + 3; next[y + s][x + s] = v + 1;
    }
    m = next;
  }
  const out = Float32Array.from(m.flat(), (v) => (v + 0.5) / (n * n));
  cache.set(n, out);
  return out;
}

export const BAYER = bayerMatrix(8);
