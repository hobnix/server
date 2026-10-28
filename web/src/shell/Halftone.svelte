<script>
  // The halftone background: a slowly drifting fractal-noise field turned into pixels by ORDERED DITHERING with an 8x8
  // Bayer matrix, drawn on a Canvas2D. Only the accent and its lighter / darker variations (--h1..--h4 from tokens.css). Never inside a button.
  // Place it as the first child of a `position: relative; overflow: hidden` box; it fills the box and ignores the pointer.
  //   <div class="card" style="position:relative;overflow:hidden"><Halftone focus={[1, 0]} /> ...content (position: relative)... </div>
  // The viewer's settings (web/src/halftone.svelte.js, the page Settings > Appearance) are the defaults of every instance. Props (all optional):
  // a slot's own PLACEMENT wins, the look comes from the settings unless the slot passes it explicitly. See.
  //   focus     [x, y] 0..1: where the glow is strongest (default top right)           (placement: the slot decides)
  //   cell      px of one cell of THIS slot (4 for card headers, 6 for large panels); the setting `size` multiplies it
  //   reach     how far the glow reaches from the focus (1 = about 55 % of the diagonal); times the setting `reach`
  //   opacity   0..1 cap for the layer; times the setting `opacity`
  //   mode, speed, contrast, matrix, grain   the look: undefined = the viewer's setting
  import { onMount } from 'svelte';
  import { theme } from '../theme.svelte.js';
  import { bayerMatrix } from './bayer.js';
  import { ht } from '../halftone.svelte.js';

  let { mode = undefined, cell = 4, speed = undefined, contrast = undefined, focus = [1, 0], reach = 1, opacity = 0.9, matrix = undefined, grain = undefined } = $props();

  // the values in force: a prop passed by the slot, else the viewer's setting (size, reach and opacity multiply the slot's value)
  const eff = () => ({
    on: ht.on,
    mode: mode ?? ht.mode,
    cell: Math.max(2, Math.round(cell * ht.size)),
    speed: ht.animate ? (speed ?? ht.speed) : 0,
    contrast: contrast ?? ht.contrast,
    reach: reach * ht.reach,
    opacity: Math.min(1, opacity * ht.opacity),
    matrix: matrix ?? ht.matrix,
    grain: grain ?? ht.grain,
  });

  let host, canvas;

  // value noise on a 3D lattice (x, y, time) with smooth interpolation; fbm = 3 octaves
  const hash = (x, y, z) => {
    let h = (x * 374761393 + y * 668265263 + z * 2147483647) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    return ((h ^ (h >>> 16)) >>> 0) / 4294967295;
  };
  const sm = (t) => t * t * (3 - 2 * t);
  function noise(x, y, z) {
    const xi = Math.floor(x), yi = Math.floor(y), zi = Math.floor(z);
    const xf = sm(x - xi), yf = sm(y - yi), zf = sm(z - zi);
    const l = (a, b, t) => a + (b - a) * t;
    return l(
      l(l(hash(xi, yi, zi), hash(xi + 1, yi, zi), xf), l(hash(xi, yi + 1, zi), hash(xi + 1, yi + 1, zi), xf), yf),
      l(l(hash(xi, yi, zi + 1), hash(xi + 1, yi, zi + 1), xf), l(hash(xi, yi + 1, zi + 1), hash(xi + 1, yi + 1, zi + 1), xf), yf),
      zf);
  }
  const fbm = (x, y, z) => (noise(x, y, z) * 0.55 + noise(x * 2.1 + 17, y * 2.1 + 5, z * 1.7) * 0.3 + noise(x * 4.3 + 3, y * 4.3 + 31, z * 2.5) * 0.15);

  // the four colours, read from the tokens (index 0 = the sparsest cells, 3 = the densest) (a probe element resolves var() and the relative colours to something the canvas understands)
  let colors = ['#9184d9', '#9184d9', '#9184d9', '#9184d9'];   // h4 (darkest) .. h3 (lightest)
  function readColors() {
    const probe = document.createElement('span');
    probe.style.cssText = 'position:absolute;visibility:hidden;pointer-events:none';
    host.appendChild(probe);
    const get = (v) => { probe.style.color = `var(${v})`; return getComputedStyle(probe).color; };
    // dark: the denser the lighter (h4 .. h3); light: the denser the DARKER, or the dots vanish on white (h3 .. h4)
    const light = getComputedStyle(document.documentElement).colorScheme.trim() === 'light';
    colors = light ? [get('--h3'), get('--h2'), get('--h1'), get('--h4')] : [get('--h4'), get('--h1'), get('--h2'), get('--h3')];
    probe.remove();
  }

  onMount(() => {
    const ctx = canvas.getContext('2d');
    const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
    let w = 0, h = 0, dpr = 1, raf = 0, last = 0, visible = true, t0 = performance.now(), still = reduced, tAcc = 0, tLast = t0;

    function size() {
      const r = host.getBoundingClientRect();
      dpr = Math.min(2, window.devicePixelRatio || 1);
      w = Math.max(1, Math.round(r.width)); h = Math.max(1, Math.round(r.height));
      canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
      canvas.style.width = w + 'px'; canvas.style.height = h + 'px';
      draw(performance.now());
    }

    function draw(now) {
      const e = eff();
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      if (!e.on) return;
      const { mode, speed, contrast, opacity, grain } = e;
      const c = e.cell;
      const M = bayerMatrix(e.matrix), mn = e.matrix, mask = mn - 1;
      // time is accumulated per frame, so a change of speed never makes the field jump
      tAcc += Math.min(0.1, (now - tLast) / 1000) * 0.12 * speed; tLast = now;
      const cols = Math.ceil(w / c), rows = Math.ceil(h / c);
      const t = (still || !ht.animate) ? 12 : tAcc;     // lattice units: one unit of z per ~8 s at speed 1
      // the glow centre drifts slowly around the focus
      const fx = (focus[0] + Math.sin(t * 1.3) * 0.08) * cols, fy = (focus[1] + Math.cos(t * 0.9) * 0.12) * rows;
      const maxd = Math.hypot(cols, rows) * 0.55 * e.reach;
      const aspect = c / Math.min(w, h) * 6;                                    // noise scale: about 6 features across the short side
      const paths = [new Path2D(), new Path2D(), new Path2D(), new Path2D()];
      for (let cy = 0; cy < rows; cy++) {
        for (let cx = 0; cx < cols; cx++) {
          const d = Math.hypot(cx - fx, (cy - fy) * 1.6) / maxd;                  // rows count more: cards are wide and short
          if (d >= 1) continue;
          let v = fbm(cx * aspect + t * 0.7, cy * aspect - t * 0.4, t);
          v = (v - 0.5) * contrast + 0.5;
          v *= Math.pow(1 - d, 1.25);                                             // fade towards the edge of the glow
          if (v <= 0) continue;
          let th = M[(cy & mask) * mn + (cx & mask)];
          if (grain > 0) th = Math.min(0.999, Math.max(0.001, th + (hash(cx, cy, 91) - 0.5) * grain));   // static jitter: the regular grain breaks up
          const x = cx * c, y = cy * c;
          if (mode === 'pixel') {
            if (v > th) paths[Math.min(3, Math.floor(v * 4))].rect(x, y, c - 1, c - 1);
          } else {
            // ordered dithering of the LEVEL: 0..3 steps decided by the Bayer threshold, so neighbouring cells step through the sizes in a pattern
            const lvl = Math.floor(v * 3.2 + th);
            if (lvl < 1) continue;
            const p = paths[Math.min(3, lvl)];
            const cxp = x + c / 2, cyp = y + c / 2;
            const kind = mode === 'mix' ? (lvl >= 3 ? 'cross' : 'dot') : mode;
            if (kind === 'dot') { const rad = (c / 2) * (0.32 + 0.22 * lvl); p.moveTo(cxp + rad, cyp); p.arc(cxp, cyp, rad, 0, 6.2832); }
            else { // pixel cross: a plus of 1 px arms (size from the level), the pixel unit is a third of the cell
              const u = c / 3;
              p.rect(cxp - u / 2, cyp - u / 2, u, u);
              if (lvl >= 2) { p.rect(cxp - u * 1.5, cyp - u / 2, u, u); p.rect(cxp + u / 2, cyp - u / 2, u, u); p.rect(cxp - u / 2, cyp - u * 1.5, u, u); p.rect(cxp - u / 2, cyp + u / 2, u, u); }
            }
          }
        }
      }
      ctx.globalAlpha = opacity;
      for (let i = 0; i < 4; i++) { ctx.fillStyle = colors[i]; ctx.fill(paths[i]); }
      ctx.globalAlpha = 1;
    }

    function frame(now) {
      raf = 0;
      if (!visible || document.hidden || still || !ht.animate || !ht.on) return;
      if (now - last >= 33) { last = now; draw(now); }      // 30 fps cap
      raf = requestAnimationFrame(frame);
    }
    const kick = () => { if (!raf && visible && !document.hidden && !still && ht.animate && ht.on) raf = requestAnimationFrame(frame); };

    readColors();
    size();
    const ro = new ResizeObserver(size);
    ro.observe(host);
    const io = new IntersectionObserver((es) => { visible = es[0]?.isIntersecting ?? true; if (visible) kick(); else if (raf) { cancelAnimationFrame(raf); raf = 0; } });
    io.observe(host);
    const vis = () => (document.hidden ? (raf && (cancelAnimationFrame(raf), (raf = 0))) : kick());
    document.addEventListener('visibilitychange', vis);
    const rm = matchMedia('(prefers-reduced-motion: reduce)');
    const rmChange = () => { still = rm.matches; draw(performance.now()); kick(); };
    rm.addEventListener?.('change', rmChange);
    kick();

    // a theme or accent change: read the colours again and draw once
    const recolor = () => { readColors(); draw(performance.now()); };
    const mo = new MutationObserver(recolor);
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'style'] });
    const mq = matchMedia('(prefers-color-scheme: dark)');
    mq.addEventListener?.('change', recolor);
    host.__recolor = recolor;
    host.__redraw = () => { tLast = performance.now(); draw(tLast); kick(); };

    return () => { cancelAnimationFrame(raf); ro.disconnect(); io.disconnect(); mo.disconnect(); mq.removeEventListener?.('change', recolor); rm.removeEventListener?.('change', rmChange); document.removeEventListener('visibilitychange', vis); };
  });

  // the toggle changes data-theme (the observer above sees it), but tokens resolve a frame later: read again when the app's flag flips
  // a change of any setting or prop (the effect reads them all through eff()) draws again at once
  $effect(() => { JSON.stringify(eff()); host?.__redraw?.(); });
  $effect(() => { theme.dark; host?.__recolor && setTimeout(host.__recolor, 50); });
</script>

<div class="ht" class:off={!ht.on} bind:this={host} aria-hidden="true"><canvas bind:this={canvas}></canvas></div>

<style>
  .ht { position: absolute; inset: 0; overflow: hidden; pointer-events: none; z-index: 0; }
  .ht.off { display: none; }
  canvas { display: block; }
</style>
