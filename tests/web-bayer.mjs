// Bayer matrix generator (web/src/shell/bayer.js): thresholds in (0,1), every rank once, 8 equals the old fixed matrix, bad sizes refused.
import assert from 'node:assert/strict';
import { bayerMatrix, BAYER, MATRIX_SIZES } from '../web/src/shell/bayer.js';

// the matrix Halftone.svelte and Spark.svelte used before the generator took a size (kept here verbatim)
const old8 = (() => {
  let m = [[0, 2], [3, 1]];
  for (let n = 2; n < 8; n *= 2) {
    const next = Array.from({ length: n * 2 }, () => new Array(n * 2));
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
      const v = m[y][x] * 4;
      next[y][x] = v; next[y][x + n] = v + 2; next[y + n][x] = v + 3; next[y + n][x + n] = v + 1;
    }
    m = next;
  }
  return Float32Array.from(m.flat(), (v) => (v + 0.5) / 64);
})();
assert.deepEqual(Array.from(BAYER), Array.from(old8), '8x8 equals the existing matrix');

for (const n of [2, 4, 8, 16, 32]) {
  const m = bayerMatrix(n);
  assert.equal(m.length, n * n);
  const ranks = Array.from(m, (t) => Math.round(t * n * n - 0.5));
  assert.ok(m.every((t) => t > 0 && t < 1), `${n}: thresholds strictly inside 0..1`);
  assert.deepEqual([...ranks].sort((a, b) => a - b), Array.from({ length: n * n }, (_, i) => i), `${n}: each rank used exactly once`);
  assert.ok(Math.abs(Array.from(m).reduce((a, b) => a + b, 0) / (n * n) - 0.5) < 1e-5, `${n}: mean 0.5`);
  // the doubling: the cell half a matrix to the right is rank + 2 (mod 4), the one half a matrix below + 3, the diagonal one + 1
  const h = n / 2;
  for (let y = 0; y < h; y++) for (let x = 0; x < h; x++) {
    const r = ranks[y * n + x];
    assert.equal(((ranks[y * n + x + h] - r) % 4 + 4) % 4, 2);
    assert.equal(((ranks[(y + h) * n + x] - r) % 4 + 4) % 4, 3);
    assert.equal(((ranks[(y + h) * n + x + h] - r) % 4 + 4) % 4, 1);
  }
}
assert.equal(bayerMatrix(16)[0], 0.5 / 256);
assert.ok(MATRIX_SIZES.every((n) => bayerMatrix(n).length === n * n));
for (const bad of [0, 1, 3, 12, 8.5, -8, NaN]) assert.throws(() => bayerMatrix(bad), `${bad} refused`);
console.log('bayer ok');
