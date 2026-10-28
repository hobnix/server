// The per-viewer halftone settings: kept in this browser only (localStorage, wrapped in try/catch; without it
// the defaults simply apply). Every <Halftone /> reads these as its defaults. A prop a slot passes still wins for what is placement
// (focus, reach, the slot's own cell size); `size`, `reach` and `opacity` here are MULTIPLIERS of the slot's value, so a small dialog header
// stays smaller than the login panel whatever is chosen. The defaults are today's look.
import { MATRIX_SIZES } from './shell/bayer.js';

const KEY = 'hs-halftone';
export const MODES = ['dots', 'pixel', 'cross', 'mix'];

// limits: [min, max, step]
export const LIMITS = {
  size: [0.5, 2.5, 0.25],      // times the slot's cell size (a slot's 4 px cell becomes 2 .. 10 px)
  speed: [0, 3, 0.1],          // 0 = a still field
  contrast: [0.6, 2.6, 0.05],
  reach: [0.4, 1.8, 0.05],     // times the slot's reach
  opacity: [0.2, 1, 0.05],     // times the slot's opacity
  grain: [0, 1, 0.05],         // random jitter on the Bayer thresholds; 0 = the clean regular pattern
};

export const DEFAULTS = Object.freeze({
  on: true,          // false = no halftone anywhere
  animate: true,     // false = one still frame ("Reduce effects"; the system's reduce-motion setting does the same without asking)
  mode: 'dots',
  matrix: 8,         // Bayer matrix size: 8 or 16
  size: 1,
  speed: 1,
  contrast: 1.35,
  reach: 1,
  opacity: 1,
  grain: 0,
});

export const ht = $state({ ...DEFAULTS });

function clamp(k, v) {
  const [lo, hi] = LIMITS[k];
  v = Number(v);
  return Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : DEFAULTS[k];
}

// one value checked against its limits / allowed list; a bad value gives the default
function clean(k, v) {
  if (k === 'on' || k === 'animate') return typeof v === 'boolean' ? v : DEFAULTS[k];
  if (k === 'mode') return MODES.includes(v) ? v : DEFAULTS.mode;
  if (k === 'matrix') return MATRIX_SIZES.includes(Number(v)) ? Number(v) : DEFAULTS.matrix;
  return clamp(k, v);
}

try {
  const saved = JSON.parse(localStorage.getItem(KEY) || '{}');
  for (const k of Object.keys(DEFAULTS)) if (k in saved) ht[k] = clean(k, saved[k]);
} catch { /* no memory, or damaged: the defaults */ }

function save() {
  try {
    const diff = {};
    for (const k of Object.keys(DEFAULTS)) if (ht[k] !== DEFAULTS[k]) diff[k] = ht[k];
    if (Object.keys(diff).length) localStorage.setItem(KEY, JSON.stringify(diff)); else localStorage.removeItem(KEY);
  } catch { /* no memory */ }
}

export function setHalftone(patch) {
  for (const [k, v] of Object.entries(patch)) if (k in DEFAULTS) ht[k] = clean(k, v);
  save();
}

export function resetHalftone() {
  Object.assign(ht, DEFAULTS);
  save();
}

export const isDefault = () => Object.keys(DEFAULTS).every((k) => ht[k] === DEFAULTS[k]);
