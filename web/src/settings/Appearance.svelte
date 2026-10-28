<script>
  // The Appearance block of the Settings page: the halftone effect, live. The preview is a real <Halftone /> with no look props, so it shows what
  // every slot gets (web/src/halftone.svelte.js holds the choices in this browser only). Mounted by pages/Settings.svelte: <Appearance />.
  import Halftone from '../shell/Halftone.svelte';
  import Combobox from '../ui/Combobox.svelte';
  import Switch from '../ui/Switch.svelte';
  import { ht, setHalftone, resetHalftone, isDefault, LIMITS, MODES } from '../halftone.svelte.js';
  import { MATRIX_SIZES } from '../shell/bayer.js';
  import { theme, toggleTheme } from '../theme.svelte.js';

  const modes = [
    { value: 'dots', label: 'Dots (round, the default)' },
    { value: 'pixel', label: 'Pixels (sharp squares)' },
    { value: 'cross', label: 'Crosses' },
    { value: 'mix', label: 'Mix (dots, crosses in the core)' },
  ];
  const sizes = MATRIX_SIZES.map((n) => ({ value: String(n), label: n === 8 ? '8 x 8 (fine grain)' : `${n} x ${n} (smoother steps)` }));

  // slider rows: key, label, hint, how the value is shown
  const rows = [
    { k: 'size', label: 'Cell size', hint: 'Times the size each place chose (a 4 px cell at 1.0)', show: (v) => `${v.toFixed(2)}x` },
    { k: 'speed', label: 'Speed', hint: '0 = a still field', show: (v) => (v === 0 ? 'still' : `${v.toFixed(1)}x`) },
    { k: 'contrast', label: 'Contrast', hint: 'Higher = a harder edge between lit and dark', show: (v) => v.toFixed(2) },
    { k: 'reach', label: 'Reach', hint: 'How far the glow spreads from its corner', show: (v) => `${v.toFixed(2)}x` },
    { k: 'opacity', label: 'Strength', hint: 'How strong the whole layer is', show: (v) => `${Math.round(v * 100)} %` },
    { k: 'grain', label: 'Grain', hint: '0 = the clean regular pattern, more breaks it up', show: (v) => `${Math.round(v * 100)} %` },
  ];

  const pct = (k) => ((ht[k] - LIMITS[k][0]) / (LIMITS[k][1] - LIMITS[k][0])) * 100;
  const reducedMotion = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
</script>

<section class="ap">
  <div class="preview" role="img" aria-label="Preview of the halftone background">
    <Halftone cell={4} focus={[0.85, 0.2]} reach={1.1} opacity={0.9} />
    <div class="cap">Preview</div>
  </div>

  <div class="ctl">
    <div class="line">
      <Switch checked={ht.on} label="Halftone background" onchange={(v) => setHalftone({ on: v })} />
      <span>Show the halftone background</span>
    </div>
    <div class="line">
      <Switch checked={ht.animate} disabled={!ht.on || reducedMotion} reason={reducedMotion ? 'Your system asks for reduced motion' : ''} label="Animate" onchange={(v) => setHalftone({ animate: v })} />
      <span>Animate{reducedMotion ? ' (off: your system asks for reduced motion)' : ' (off = reduce effects: one still picture)'}</span>
    </div>

    <div class="grid" class:dim={!ht.on}>
      <div class="field">
        <label for="ht-mode">Shape</label>
        <Combobox id="ht-mode" options={modes} value={ht.mode} onchange={(v) => MODES.includes(v) && setHalftone({ mode: v })} wide />
      </div>
      <div class="field">
        <label for="ht-matrix">Dither matrix</label>
        <Combobox id="ht-matrix" options={sizes} value={String(ht.matrix)} onchange={(v) => setHalftone({ matrix: Number(v) })} wide />
      </div>

      {#each rows as r (r.k)}
        <div class="field">
          <label for={'ht-' + r.k}>{r.label}<b>{r.show(ht[r.k])}</b></label>
          <input id={'ht-' + r.k} type="range" min={LIMITS[r.k][0]} max={LIMITS[r.k][1]} step={LIMITS[r.k][2]} value={ht[r.k]}
                 style:--p={pct(r.k) + '%'} oninput={(e) => setHalftone({ [r.k]: e.currentTarget.valueAsNumber })} />
          <span class="hint">{r.hint}</span>
        </div>
      {/each}
    </div>

    <div class="actions">
      <button type="button" class="btn" onclick={resetHalftone} disabled={isDefault()}>Reset to default</button>
      <button type="button" class="btn btn-ghost" onclick={toggleTheme}>{theme.dark ? 'Switch to light theme' : 'Switch to dark theme'}</button>
    </div>
    <p class="note">Kept in this browser only. The accent colour comes from the server setting.</p>
  </div>
</section>

<style>
  .ap { display: grid; grid-template-columns: minmax(0, 1fr); gap: 16px; }
  .preview { position: relative; overflow: hidden; height: 190px; border: 1px solid var(--line-2); background: var(--panel); }
  .cap { position: relative; padding: 8px 12px; font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-3); }
  .ctl { display: flex; flex-direction: column; gap: 14px; }
  .line { display: flex; align-items: center; gap: 10px; font-size: 13.5px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 16px 24px; }
  .grid.dim { opacity: 0.5; }
  .field > label { display: flex; justify-content: space-between; gap: 8px; }
  .field > label b { font-weight: 500; color: var(--fg); letter-spacing: 0; }
  .hint { font-size: 12px; color: var(--fg-3); }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; }
  .note { margin: 0; font-size: 12px; color: var(--fg-3); }

  /* range: a hard-edged track filled with the accent up to the value, a square thumb */
  input[type='range'] { -webkit-appearance: none; appearance: none; width: 100%; height: 18px; margin: 0; background: transparent; cursor: pointer; }
  input[type='range']::-webkit-slider-runnable-track { height: 6px; background: linear-gradient(to right, var(--accent) var(--p), var(--panel-3) var(--p)); border: 1px solid var(--line-2); border-radius: 0; }
  input[type='range']::-moz-range-track { height: 6px; background: var(--panel-3); border: 1px solid var(--line-2); border-radius: 0; }
  input[type='range']::-moz-range-progress { height: 6px; background: var(--accent); border-radius: 0; }
  input[type='range']::-webkit-slider-thumb { -webkit-appearance: none; width: 12px; height: 18px; margin-top: -7px; background: var(--fg); border: 1px solid var(--bg); border-radius: 0; }
  input[type='range']::-moz-range-thumb { width: 10px; height: 16px; background: var(--fg); border: 1px solid var(--bg); border-radius: 0; }
  input[type='range']:hover::-webkit-slider-thumb { background: var(--accent-ink); }
  input[type='range']:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
</style>
