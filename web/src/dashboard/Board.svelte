<script>
  // THE tile component: the dashboard as sections of tiles. Props: doc (the document of GET /api/board), host (location.hostname, for the Incus tile).
  //   <Board {doc} host={location.hostname} />
  import Banner from '../ui/Banner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import { groupTiles, iconFor, incusTile, monogram } from './board.js';

  let { doc = null, host = '' } = $props();
  const all = $derived([...(doc?.tiles ?? []), ...(doc?.incus_ui ? [incusTile(host)] : [])]);
  const groups = $derived(groupTiles(all));
</script>

{#if doc?.locked}
  <Banner tone="warn">Storage is locked. The tiles appear after it is unlocked.</Banner>
{:else if !groups.length}
  <EmptyState icon="squares-four" title="No service wants a tile yet" text="A service that describes a tile (hs services) shows up here." />
{:else}
  {#each groups as g (g.group)}
    <section>
      <h3 class="card-kicker">{g.group}</h3>
      <div class="grid">
        {#each g.tiles as t (t.service + t.title + t.href)}
          {@const ic = iconFor(t.icon)}
          <a class="tile" href={t.href} target="_blank" rel="noopener noreferrer">
            <span class="ico">{#if ic}<i class="ph ph-{ic}" style="font-size:22px"></i>{:else}<b>{monogram(t.title)}</b>{/if}</span>
            <span class="tx">
              <span class="ti">{t.title}</span>
              {#if t.description}<span class="de">{t.description}</span>{/if}
            </span>
            {#if t.stats?.length}
              <span class="st">
                {#each t.stats as s}<span class="sv"><span class="v">{s.value}{s.unit ? ' ' + s.unit : ''}</span><span class="l">{s.label}</span></span>{/each}
              </span>
            {/if}
          </a>
        {/each}
      </div>
    </section>
  {/each}
{/if}

<style>
  section { margin-bottom: var(--space-4); }
  h3 { margin: 0 0 var(--space-2); }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: var(--space-2); }
  .tile { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; padding: 12px 14px; border: 1px solid var(--line); border-radius: var(--r); background: var(--panel); color: var(--fg); text-decoration: none; }
  .tile:hover, .tile:focus-visible { border-color: var(--accent); }
  .ico { flex: none; width: 36px; height: 36px; display: grid; place-items: center; border: 1px solid var(--line); border-radius: var(--r); color: var(--accent); background: var(--panel-2, var(--panel)); }
  .ico b { font-size: 16px; font-weight: 600; }
  .tx { display: flex; flex-direction: column; min-width: 0; flex: 1; }
  .ti { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .de { font-size: 12px; color: var(--fg-3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .st { display: flex; gap: 14px; width: 100%; padding-top: 6px; border-top: 1px solid var(--line); }
  .sv { display: flex; flex-direction: column; }
  .v { font: 500 12px var(--mono); color: var(--fg-2); }
  .l { font-size: 11px; color: var(--fg-3); }
</style>
