<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // The shared table. Columns are declared, the rows are data; a click on a header sorts by it (ascending, descending, back to the order the
  // data came in). The header sticks to the top while the page scrolls (see `.table thead th` in nocturne.css). A cell is drawn by the `cell`
  // snippet when the page gives one, else it shows the value.
  //
  //   <Table id="shares" {columns} rows={items} key="name" onrow={(r) => open(r)} selected={sel?.name} empty="No shares.">
  //     {#snippet cell(row, col)} ... {/snippet}
  //   </Table>
  //
  // column: { key, label, sort?: 'text' | 'num' | (a, b) => number | false, value?: (row) => any, align?: 'right', width?: '120px', cls?: 'name', optional?: true }
  //   `optional: true` = hidden on a phone (up to 860 px), so the table keeps its important columns readable.
  //   `sort` defaults to 'text' ('num' for numbers: sizes, counts, dates as epoch); false = not sortable. `value` is what is compared (and shown by default).
  //   A row's empty value (null, '', '-', NaN) always sorts last, whichever way the table is sorted.
  // `id` keeps the chosen sort for the browser session. `sort` = { key, dir: 'asc' | 'desc' } is the sort a table starts with.
  import { untrack } from 'svelte';
  import { sortRows, nextOrder, valueOf } from './sort.js';
  import { tr } from '../i18n.js';

  let { columns, rows = [], key = null, id = '', sort = null, onrow = null, selected = null, empty = 'Nothing to show.', loading = false, cell = null, rowClass = null, compact = false } = $props();

  const store = (v) => { try { v === undefined ? sessionStorage.removeItem('tbl:' + id) : sessionStorage.setItem('tbl:' + id, JSON.stringify(v)); } catch { /* private mode: no memory */ } };
  const stored = () => { try { return id ? JSON.parse(sessionStorage.getItem('tbl:' + id) ?? 'null') : null; } catch { return null; } };

  let order = $state(untrack(() => stored() ?? sort));   // { key, dir } or null = the order of the data

  const sorted = $derived(sortRows(rows, columns, order));

  function toggle(col) {
    order = nextOrder(order, col);
    store(order ?? undefined);
  }
  // a clickable row is reachable with Tab and opens with Enter or Space (a key pressed on a button inside the row is that button's own)
  function rowkey(e, row) {
    if (e.target !== e.currentTarget || (e.key !== 'Enter' && e.key !== ' ')) return;
    e.preventDefault();
    onrow(row);
  }
  const aria = (col) => (order?.key === col.key ? (order.dir === 'asc' ? 'ascending' : 'descending') : 'none');
</script>

<div class="tablescroll">
<table class="table" class:compact>
  <thead>
    <tr>
      {#each columns as col (col.key)}
        <th class:opt={col.optional} style:text-align={col.align} style:width={col.width} aria-sort={col.sort === false ? undefined : aria(col)}>
          {#if col.sort === false || !col.label}
            {tr(col.label) ?? ''}
          {:else}
            <button class="sortbtn" class:on={order?.key === col.key} onclick={() => toggle(col)} use:tip={`${tr('Sort by')} ${tr(col.label)}`}>
              {tr(col.label)}<i class="ph ph-{order?.key === col.key ? (order.dir === 'asc' ? 'caret-up' : 'caret-down') : 'caret-up-down'}"></i>
            </button>
          {/if}
        </th>
      {/each}
    </tr>
  </thead>
  <tbody>
    {#each sorted as row, i (key ? row[key] : i)}
      <tr class={rowClass ? rowClass(row) : ''} class:clickable={!!onrow} class:selected={key && selected !== null && row[key] === selected} aria-current={key && selected !== null && row[key] === selected ? 'true' : undefined}
          tabindex={onrow ? 0 : undefined} onclick={onrow ? () => onrow(row) : null} onkeydown={onrow ? (e) => rowkey(e, row) : null}>
        {#each columns as col (col.key)}
          <td style:text-align={col.align} class:opt={col.optional} class={col.cls ?? ''}>
            {#if cell}{@render cell(row, col)}{:else}{valueOf(col, row) ?? ''}{/if}
          </td>
        {/each}
      </tr>
    {:else}
      <tr class="none"><td colspan={columns.length}>{loading ? 'Loading…' : empty}</td></tr>
    {/each}
  </tbody>
</table>
</div>

<style>
  .sortbtn { all: unset; cursor: pointer; display: inline-flex; align-items: center; gap: 4px; text-transform: inherit; letter-spacing: inherit; font: inherit; color: inherit; }
  .sortbtn i { font-size: 11px; opacity: 0; transition: opacity 0.1s; }
  .sortbtn:hover i, .sortbtn.on i { opacity: 0.8; }
  .sortbtn.on { color: var(--fg); }
  .sortbtn:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  tr.clickable { cursor: pointer; }
  /* the selected row: a tint and the accent marker on its left edge */
  tr.selected td { background: color-mix(in oklch, var(--accent) 12%, transparent); }
  tr.selected td:first-child { box-shadow: inset 2px 0 0 var(--accent); }
  tr.none td { color: var(--fg-3); font-size: 12.5px; padding: 12px; }
  .compact td { padding-block: 4px; }
  td { vertical-align: middle; }
  @media (max-width: 860px) { .opt { display: none; } }
</style>
