<script>
  // The data-driven page: a page that is a DECLARATION, not a component. The same renderer draws the
  // pages of extension packages (their manifest's [web.page] reaches here through the session answer, pages/Extension.svelte) and any simple core
  // page that is only "a head, some tabs, a table, a drawer".
  //
  //   <GenericPage spec={...} forms={{ PcForm }} />
  //
  // spec = {
  //   title, crumb?, sub?,
  //   actions?: [{ label, icon?, primary?, danger?, plan: [area, arg, ...], planTitle? }   // opens the plan dialog (openPlan): the ONLY way a page changes anything
  //            | { label, form: 'Name' }],                                                  // opens a form of `forms` (a CreateDialog component)
  //   tabs?: [{ id, label }],                                                               // page tabs; a block with `tab` shows only on that tab
  //   blocks: [block, ...] }
  //
  // block (all take `tab?`, `title?`, `actions?`):
  //   { type: 'table',   read: '/api/sys/...', key: 'name', columns: [col], joins?: [{ read, key, as, col }], rowActions?: [action], empty?, emptyTitle?,
  //                      onrow?: 'drawer', drawer?: { title: '{name}', chip?: '{kind}', state?: 'colKey', tabs?: [{ id, label }], blocks: [block], actions?: [action] } }
  //   { type: 'kv',      read?, items: [{ k, col }]  (first row)  |  pairs: true (rows are key, value)  |  items: [{ k, field }] inside a drawer }
  //   { type: 'cards',   read, key, cardTitle: '{name}', columns, rowActions? }                  // one card per row
  //   { type: 'text',    text: 'a paragraph' | ['p1', 'p2'] }
  //   { type: 'empty',   icon?, title, text?, actions? }
  //   { type: 'gallery', read, key, image: '/api/poster/{file|u}', columns, rowActions? }        // big picture + thumbnails (a new row is shown at once)
  //
  // col: { key, label, col?: n  (field of the answer row, default = position), kind?: 'text' | 'mono' | 'dot' | 'usage' | 'chip' | 'switch',
  //        fmt?: 'bytes' | 'datetime' | 'words', icon?, optional?: true (hidden on a phone), align?, sort?: false,
  //        map?: { value: [state, word] }          // kind 'dot': ok | warn | bad | info | off
  //        used?, size?, free?: column keys         // kind 'usage' -> UsageBar
  //        plan?: [area, ...], planTitle? }         // kind 'switch': toggling opens this plan; {checked} is 'on' | 'off'
  // Templates: "{col}" is the row's value of that column, "{col|u}" URL-encoded. They work in plan args, planTitle, title, href, drawer.title, image.
  // action: { label, icon?, title?, primary?, danger?, iconOnly?, plan?, planTitle?, form?, props?, href?, download? }
  //
  // Reads are polled (data.svelte.js) and wrapped in PageState (loading, error with stale data, empty). Locked / switched off / unreachable are PageFrame's.
  // `data` = { '/api/sys/x': { rows: [[...]] } } shows these answers instead of polling (a mock backend, a test). Nothing else here talks to the server.
  import PageHeader from './PageHeader.svelte';
  import GenBlock from './GenBlock.svelte';
  import { tr } from '../i18n.js';
  import { openPlan, openCreate } from '../ui.svelte.js';
  import { tpl, planArgs } from './generic.js';

  let { spec, forms = {}, data = null } = $props();

  let tab = $state('');
  const active = $derived(tab || spec.tabs?.[0]?.id || '');
  const blocks = $derived((spec.blocks ?? []).filter((b) => !b.tab || b.tab === active));

  function run(a) {
    if (a.form) openCreate(forms[a.form], a.props ?? {});
    else if (a.plan) openPlan(a.plan[0], planArgs(a.plan, {}), tpl(a.planTitle ?? a.label, {}));
  }
</script>

<div class="gp">
  <PageHeader title={spec.title} crumb={spec.crumb} sub={spec.sub}>
    {#snippet actions()}
      {#each spec.actions ?? [] as a}
        <button class="btn {a.primary ? 'btn-primary' : a.danger ? 'btn-danger' : 'btn-secondary'}" disabled={a.form && !forms[a.form]} onclick={() => run(a)}>{#if a.icon}<i class="ph ph-{a.icon}"></i>{/if}{a.label}</button>
      {/each}
    {/snippet}
  </PageHeader>
  {#if spec.tabs?.length}
    <div class="ptabs" role="tablist">
      {#each spec.tabs as t (t.id)}
        <button class="ptab" class:on={active === t.id} role="tab" aria-selected={active === t.id} onclick={() => (tab = t.id)}>{tr(t.label)}</button>
      {/each}
    </div>
  {/if}
  {#each blocks as b, i (i + ':' + (b.read ?? b.type))}
    <GenBlock block={b} {forms} {data} />
  {/each}
</div>

<style>
  .gp { display: flex; flex-direction: column; gap: 14px; }
  .ptabs { display: flex; gap: 2px; border-bottom: 1px solid var(--line); overflow-x: auto; }
  .ptab { position: relative; flex: none; height: 38px; padding: 0 14px; border: 0; background: none; color: var(--fg-2); font-weight: 500; cursor: pointer; }
  .ptab:hover, .ptab.on { color: var(--fg); }
  .ptab.on::after { content: ''; position: absolute; left: 10px; right: 10px; bottom: -1px; height: 2px; background: linear-gradient(90deg, var(--h2), var(--h1), var(--h4)); }
</style>
