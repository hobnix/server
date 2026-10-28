// The sorting of the shared table (Table.svelte), kept apart so it can be tested without a browser.
//
//   sortRows(rows, columns, order)  -> a new array; order = { key, dir: 'asc' | 'desc' } or null (the order the data came in)
//   nextOrder(order, col)           -> the order a click on the header of `col` leads to: ascending, descending, none
//
// A column compares `col.value(row)` (else row[col.key]) as text ('text', natural order: "disk2" before "disk10"), as numbers ('num') or with its own
// function. `first(row)` (optional) keeps the rows it is true for above the others in either direction. An empty value (null, undefined, '', '-', NaN) always sorts last, whichever way the table is sorted; equal values keep the data's order.
const text = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });

export const valueOf = (col, row) => (col.value ? col.value(row) : row[col.key]);
export const blank = (v) => v === null || v === undefined || v === '' || v === '-' || (typeof v === 'number' && Number.isNaN(v));

function compare(col) {
  if (typeof col.sort === 'function') return col.sort;
  if (col.sort === 'num') return (a, b) => Number(a) - Number(b);
  return (a, b) => text.compare(String(a), String(b));
}

export function sortRows(rows, columns, order, first = null) {
  if (!order) return rows;
  const col = columns.find((c) => c.key === order.key);
  if (!col || col.sort === false) return rows;
  const cmp = compare(col);
  const sign = order.dir === 'desc' ? -1 : 1;
  return rows
    .map((r, i) => ({ r, i, v: valueOf(col, r) }))
    .sort((x, y) => {
      if (first) { const fx = first(x.r), fy = first(y.r); if (fx !== fy) return fx ? -1 : 1; }   // e.g. folders stay on top whichever way it is sorted
      const bx = blank(x.v), by = blank(y.v);
      if (bx || by) return bx === by ? x.i - y.i : bx ? 1 : -1;
      return sign * cmp(x.v, y.v) || x.i - y.i;
    })
    .map((x) => x.r);
}

export function nextOrder(order, col) {
  if (col.sort === false) return order;
  if (!order || order.key !== col.key) return { key: col.key, dir: 'asc' };
  return order.dir === 'asc' ? { key: col.key, dir: 'desc' } : null;
}
