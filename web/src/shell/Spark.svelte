<script>
  // A small sparkline of the last readings (0 to 100) drawn as DITHERED PIXEL COLUMNS, in the spirit of the halftone: each reading is a column of
  // 3 px squares, the partly filled top square is decided by the same 8x8 Bayer matrix as the background, so the edge is grainy rather than a line.
  // Colours come from the tokens (--h1 body, --h3 top pixel); a reading at or over `hot` (percent) turns --warn. Fewer than two readings draw
  // nothing but keep the 22 px the line needs, so the cards do not jump. The newest reading is the rightmost column.
  //   <Spark values={cpuHist} />   <Spark values={memHist} hot={90} />
  import { BAYER } from './bayer.js';
  let { values = [], hot = 90 } = $props();

  const PX = 3, GAP = 1, ROWS = 7;                    // 7 rows x 3 px = 21 px, one px of air
  let width = $state(0);
  const cols = $derived(Math.max(0, Math.floor((width + GAP) / (PX + GAP))));
  const shown = $derived(values.length < 2 ? [] : values.slice(-cols));
  const cells = $derived.by(() => {
    const out = [];
    const off = cols - shown.length;                  // right aligned
    shown.forEach((v, i) => {
      const x = (off + i) * (PX + GAP);
      const level = (Math.min(100, Math.max(0, v)) / 100) * ROWS;
      const full = Math.floor(level), frac = level - full;
      const hotCol = v >= hot;
      for (let r = 0; r < full; r++) out.push({ x, y: (ROWS - 1 - r) * PX + 1, top: r === full - 1 && frac < 0.01, hot: hotCol });
      if (frac > 0 && frac > BAYER[(full & 7) * 8 + ((off + i) & 7)]) out.push({ x, y: (ROWS - 1 - full) * PX + 1, top: true, hot: hotCol });
    });
    return out;
  });
</script>

<div class="spark" bind:clientWidth={width} aria-hidden="true">
  <svg width={width} height={ROWS * PX + 1} style="display:block">
    {#each cells as c}<rect x={c.x} y={c.y} width={PX} height={PX} fill={c.hot ? 'var(--warn)' : c.top ? 'var(--h3)' : 'var(--h1)'} />{/each}
  </svg>
</div>

<style>
  .spark { width: 100%; height: 22px; overflow: hidden; }
</style>
