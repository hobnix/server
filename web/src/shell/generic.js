// Pure helpers of the generic page (GenericPage.svelte, GenBlock.svelte): templates, row building, value formats. No Svelte here, so a test can run them.
import { bytes } from '../format.js';

// "{name}" -> the row's value; "{file|u}" -> URL-encoded. A missing value is an empty string.
export const tpl = (s, row = {}) => String(s ?? '').replace(/\{(\w+)(?:\|(\w+))?\}/g, (_, k, f) => { const v = row?.[k] ?? ''; return f === 'u' ? encodeURIComponent(v) : String(v); });

// the arguments of a plan declaration [area, arg, ...] with the row's values put in
export const planArgs = (plan, row) => plan.slice(1).map((a) => tpl(a, row));

// "-" is how the sys commands write "nothing" in a tab-separated field
const clean = (v) => (v === '-' ? '' : v);

// answer rows (arrays) -> objects by the declared columns: column i takes field `col` (default: its own position). `joins` add a field from another read.
// joins: [{ key, as, col }] with the answers [[row, ...], ...] in the same order: the join row whose FIRST field equals this row's `key` gives field `col`.
export function buildRows(answerRows, columns = [], joins = [], joinRows = []) {
  const maps = joins.map((j, i) => Object.fromEntries((joinRows[i] ?? []).map((r) => [r[0], r[j.col ?? 1]])));
  return answerRows.map((r) => {
    const o = {};
    columns.forEach((c, i) => { o[c.key] = clean(r[c.col ?? i]); });
    joins.forEach((j, i) => { o[j.as] = maps[i][o[j.key]]; });
    return o;
  });
}

const slug = (f) => String(f).replace(/^poster-/, '').replace(/\.png$/, '').replace(/-(\d+)$/, ' · seed $1').replace(/-/g, ' ');

// value formats of a column (`fmt`): bytes, datetime (epoch seconds), words (a file name as words)
export function fmtValue(fmt, v) {
  if (v === undefined || v === null || v === '') return '';
  if (fmt === 'bytes') return bytes(Number(v));
  if (fmt === 'datetime') return new Date(Number(v) * 1000).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
  if (fmt === 'words') return slug(v);
  return String(v);
}

// a dot column: the value -> [state, word]
export const dotOf = (col, v) => col.map?.[v] ?? ['off', v === undefined || v === '' ? 'not available' : String(v)];

// the switch columns read these as "on"
export const isOn = (v) => /^(1|yes|true|on|enabled)$/i.test(String(v ?? ''));
