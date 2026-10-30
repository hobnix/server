<script>
  import { onMount } from 'svelte';
  import { poll } from '../data.svelte.js';
  import { go, url } from '../route.svelte.js';
  import { ui } from '../ui.svelte.js';
  import { docPath } from '../docs/docs.js';
  import { changes, load, markSeen, parseChanges } from '../changes.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import Banner from '../ui/Banner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import Skeleton from '../ui/Skeleton.svelte';
  import Combobox from '../ui/Combobox.svelte';

  const MODES = [
    { value: 'visit', label: 'Since my last visit' },
    { value: 'update', label: 'Since the last update' },
    { value: 'all', label: 'All' },
  ];
  const GROUPS = [['feature', 'New'], ['fix', 'Fixed'], ['change', 'Changed'], ['security', 'Security']];

  let mode = $state('visit');
  // the revision this user had seen when the page opened: marking it seen later must not empty the list under their eyes
  let base = $state(null);
  onMount(async () => {
    if (!changes.loaded) await load();
    base = changes.seen;
  });

  const path = $derived(base === null ? '' : mode === 'all' ? '/api/sys/changes/list?since=2000-01-01'
    : mode === 'visit' && base ? `/api/sys/changes/list?from=${base}` : '/api/sys/changes/list');
  const list = poll(() => path, 60000);
  const parsed = $derived(parseChanges(list.data));
  const groups = $derived(GROUPS.map(([type, label]) => ({ label, items: parsed.entries.filter((e) => e[3] === type) })).filter((g) => g.items.length));
  const empty = $derived(list.loaded && !parsed.entries.length);
  const emptyTitle = $derived(mode === 'all' ? 'No changes yet' : mode === 'update' || !base ? 'Nothing new since the last update' : 'Nothing new since your last visit');
  const emptyText = $derived(mode === 'all' ? 'The changelog has no entries.' : 'Choose Since the last update or All to see earlier changes.');

  // seen: once the list of this visit is on screen
  let marked = '';
  $effect(() => {
    if (mode === 'visit' && list.loaded && parsed.head && marked !== parsed.head) { marked = parsed.head; markSeen(parsed.head); }
  });

  const n = $derived(parsed.entries.length);
  const sub = $derived(mode === 'all' ? 'Every change in the changelog.'
    : mode === 'update' || !base ? 'Everything since the last update.'
    : n ? `${n} change${n === 1 ? '' : 's'} since your last visit.` : 'Nothing new since your last visit.');

  const paragraphs = (body) => (body && body !== '-' ? body.split(/(?:\\n){2,}/).map((p) => p.replace(/\\n/g, ' ').trim()).filter(Boolean) : []);
  const target = (docs) => {
    const [guide, anchor = ''] = docs.split('#');
    return { path: docPath('en', guide), anchor };
  };
  const href = (docs) => { const t = target(docs); return url(t.path) + (t.anchor ? '#' + t.anchor : ''); };
  function openGuide(e, docs) {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button) return;
    e.preventDefault();
    const t = target(docs);
    go(t.path);
    // the Docs page scrolls to the anchor of the address once the guide is loaded
    if (t.anchor) history.replaceState(null, '', href(docs));
  }
</script>

<div class="page">
  <PageHeader title="What's new" crumb={ui.host} {sub}>
    {#snippet actions()}
      <Combobox options={MODES} bind:value={mode} label="Show changes" />
    {/snippet}
  </PageHeader>

  {#if list.error && !list.data}
    <Banner tone="bad">The list of changes could not be read.</Banner>
  {:else if !list.loaded}
    <div class="card"><Skeleton lines={5} /></div>
  {:else if empty}
    <EmptyState icon="sparkle" title={emptyTitle} text={emptyText} />
  {:else}
    {#each groups as g}
      <div class="card grp">
        <h6>{g.label}</h6>
        {#each g.items as e}
          <div class="item">
            <span class="date mono">{e[2]}</span>
            <div class="what">
              <div class="title">{e[4]}</div>
              {#each paragraphs(e[6]) as p}<p>{p}</p>{/each}
              {#if e[5] && e[5] !== '-'}
                <a class="guide" href={href(e[5])} onclick={(ev) => openGuide(ev, e[5])}>Read the guide<i class="ph ph-arrow-right"></i></a>
              {/if}
            </div>
          </div>
        {/each}
      </div>
    {/each}
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 16px; }
  .grp { padding: 12px 16px; }
  h6 { margin: 0 0 4px; }
  .item { display: flex; gap: 16px; padding: 10px 0; box-shadow: inset 0 -1px 0 color-mix(in srgb, var(--fg) 6%, transparent); }
  .item:last-child { box-shadow: none; }
  .date { flex: none; width: 88px; font-size: 12px; color: var(--fg-3); padding-top: 2px; }
  .what { flex: 1; min-width: 0; }
  .title { font-size: 14px; }
  p { margin: 4px 0 0; font-size: 13px; color: var(--fg-2); word-break: break-word; }
  .guide { display: inline-flex; align-items: center; gap: 4px; margin-top: 6px; font-size: 12px; color: var(--accent); }
</style>
