<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows } from '../data.svelte.js';
  import { get } from '../api.js';
  import { ui, openPlan } from '../ui.svelte.js';
  import { go } from '../route.svelte.js';
  import PageHeader from '../shell/PageHeader.svelte';
  import StatusDot from '../ui/StatusDot.svelte';
  import Chip from '../ui/Chip.svelte';

  // The look of the interface (agent E, web/src/settings/Appearance.svelte): mounted when the file exists. A glob import is an import that may find
  // nothing, so a build without the file still works.
  // TODO(phase 2E): once Appearance.svelte is merged this stays as it is; nothing to change here.
  const appearance = import.meta.glob('../settings/Appearance.svelte', { eager: true });
  const Appearance = Object.values(appearance)[0]?.default ?? null;

  // The optional parts and the extensions (hs sys parts list): name, on|off, extension|part, nix (yes = needs a rebuild), switch (yes = machine.toml), title.
  // A switch opens the plan first; a part with a NixOS module takes effect at the next rebuild, an extension without one at once.
  const partList = poll('/api/sys/parts/list', 15000);
  const parts = $derived(rows(partList).map((r) => ({ name: r[0], on: r[1] === 'on', kind: r[2], nix: r[3] === 'yes', canSwitch: r[4] === 'yes', title: r[5] })));
  const extensions = $derived(parts.filter((p) => p.kind === 'extension'));
  const plainParts = $derived(parts.filter((p) => p.kind !== 'extension' && !p.name.startsWith('edge-')));
  const flip = (p) => openPlan('parts', [p.on ? 'disable' : 'enable', p.name], `${p.on ? 'Switch off' : 'Switch on'} ${p.name}`);
  const nodeList = poll('/api/sys/node/list', 30000);

  const list = poll('/api/sys/config/list', 8000);

  // section, key, current, default, type, help, settable
  const opts = $derived(rows(list).map((r) => ({ section: r[0], key: r[1], cur: r[2], dflt: r[3], type: r[4], help: r[5], settable: r[6] === 'yes' })));
  // the sections in the order of the example
  const sections = $derived.by(() => {
    const out = [];
    for (const o of opts) {
      let s = out.find((x) => x.title === o.section);
      if (!s) out.push((s = { title: o.section, fields: [] }));
      s.fields.push(o);
    }
    return out;
  });

  // What the person typed, per key. The server keeps a read for up to 30 s, so after a change the list still shows the old value for a
  // moment: the typed value stays on screen (marked "applying") until the list agrees or 40 s have passed.
  let drafts = $state({});
  const shown = (o) => (o.key in drafts ? drafts[o.key].value : o.cur);

  $effect(() => {
    for (const o of opts) {
      const d = drafts[o.key];
      if (d && d.sent && (o.cur === d.value || Date.now() - d.sent > 40000)) delete drafts[o.key];
    }
  });
  $effect(() => {
    // when the plan dialog goes away, the drafts that were sent to it are waiting for the list; the others were not asked for
    if (!ui.dialog) for (const k of Object.keys(drafts)) { if (drafts[k].asked && !drafts[k].sent) drafts[k].sent = Date.now(); }
  });
  $effect(() => {
    // a cancelled dialog changed nothing: after the grace time the field is back to the file's value
    const t = setInterval(() => {
      for (const k of Object.keys(drafts)) if (drafts[k].sent && Date.now() - drafts[k].sent > 40000) delete drafts[k];
    }, 5000);
    return () => clearInterval(t);
  });

  function commit(o, value) {
    value = value.trim();
    if (value === o.cur) { delete drafts[o.key]; return; }
    drafts[o.key] = { value, asked: true, sent: 0 };
    openPlan('config', ['set', o.key, value], `Set ${o.key}`);
  }
  const onKey = (e, o) => { if (e.key === 'Enter') commit(o, e.currentTarget.value); };

  let chk = $state(null);          // { text, rc } of the last check
  let chkBusy = $state(false);
  let chkError = $state('');
  async function runCheck() {
    chkBusy = true; chkError = '';
    try { chk = await get('/api/sys/config/check'); }
    catch (e) { chkError = e.message; }
    finally { chkBusy = false; }
  }
</script>

<div class="page">
  <PageHeader title="Settings" crumb={ui.host} sub="/etc/nixos/machine.toml and the settings that need no rebuild.">
    {#snippet actions()}
      <button use:tip={chkBusy ? 'A check is running' : 'Look for typos and missing values in machine.toml'} class="btn b13" onclick={runCheck} disabled={chkBusy}><i class="ph ph-check-square"></i>Check</button>
      <button class="btn btn-primary b13" disabled use:tip={'Run hs rebuild on the server to apply the settings'}><i class="ph ph-hammer"></i>Apply · rebuild</button>
    {/snippet}
  </PageHeader>

  {#if chk || chkError}
    <div class="card elev-sm res" class:bad={chk && chk.rc !== 0} role="status">
      <div class="rh">
        <i class="ph ph-{chkError || chk.rc !== 0 ? 'warning-circle' : 'check-circle'}" style="color:{chkError || chk.rc !== 0 ? 'var(--st-bad)' : 'var(--st-ok)'}"></i>
        <span>{chkError ? 'The check could not run.' : chk.rc === 0 ? 'machine.toml is fine' : 'machine.toml has problems'}</span>
        <span style="flex:1"></span>
        <button use:tip={'Close the result'} class="btn btn-ghost btn-icon x" aria-label="Close" onclick={() => { chk = null; chkError = ''; }}><i class="ph ph-x"></i></button>
      </div>
      <pre>{chkError || chk.text.trim()}</pre>
    </div>
  {/if}

  {#if Appearance}<Appearance />{/if}

  <div class="cols">
    <div class="card sec" id="parts">
      <div class="st">Parts</div>
      <p class="hp2">Optional parts of this server. Off means its pages and commands are not there. A part with a NixOS module changes at the next <code>hs rebuild</code>.</p>
      {#each plainParts as p (p.name)}
        <div class="prow">
          <StatusDot state={p.on ? 'ok' : 'off'} label={p.on ? 'on' : 'off'} bare />
          <div class="pt"><code>{p.name}</code><span class="hp">{p.title}</span></div>
          {#if p.nix}<Chip>rebuild</Chip>{/if}
          <button use:tip={!p.canSwitch ? 'This part cannot be switched here' : p.on ? 'Switch this part off (shows the plan)' : 'Switch this part on (shows the plan)'} class="btn sm" disabled={!p.canSwitch} onclick={() => flip(p)}>{p.on ? 'Switch off…' : 'Switch on…'}</button>
        </div>
      {:else}
        <div class="hp2">{partList.loaded ? (partList.error ? 'The parts could not be read.' : 'No optional parts.') : 'Loading…'}</div>
      {/each}
    </div>
    <div class="card sec" id="extensions">
      <div class="st">Extensions</div>
      <p class="hp2">Packages that add pages and commands (<code>hs ext</code>). Off by default; one without a NixOS module is on at once.</p>
      {#each extensions as p (p.name)}
        <div class="prow">
          <StatusDot state={p.on ? 'ok' : 'off'} label={p.on ? 'on' : 'off'} bare />
          <div class="pt"><code>{p.name}</code><span class="hp">{p.title}</span></div>
          {#if p.nix}<Chip>rebuild</Chip>{/if}
          <button use:tip={!p.canSwitch ? 'This part cannot be switched here' : p.on ? 'Switch this part off (shows the plan)' : 'Switch this part on (shows the plan)'} class="btn sm" disabled={!p.canSwitch} onclick={() => flip(p)}>{p.on ? 'Switch off…' : 'Switch on…'}</button>
        </div>
      {:else}
        <div class="hp2">{partList.loaded ? 'No extensions on this server.' : 'Loading…'}</div>
      {/each}
    </div>
    <div class="card sec" id="nodes">
      <div class="st">Nodes</div>
      <p class="hp2">The other servers this one looks at: {rows(nodeList).length} on the list. Adding, removing and the keys are on the Nodes page.</p>
      <button use:tip={'Open the list of servers'} class="btn sm" style="align-self:flex-start" onclick={() => go('/nodes')}><i class="ph ph-hard-drives"></i>Open Nodes</button>
    </div>
  </div>

  {#if sections.length}
    <div class="cols">
      {#each sections as s (s.title)}
        <div class="card elev-sm sec">
          <div class="st">{s.title}</div>
          {#each s.fields as o (o.key)}
            {@const d = drafts[o.key]}
            <div class="fld">
              <div class="k"><code>{o.key}</code></div>
              <div class="v">
                {#if o.settable && o.type === 'bool'}
                  <select class="input in" value={shown(o)} onchange={(e) => commit(o, e.currentTarget.value)} aria-label={o.key}>
                    <option value="">default ({o.dflt})</option>
                    <option value="true">true</option>
                    <option value="false">false</option>
                  </select>
                {:else if o.settable}
                  <input class="input in" value={shown(o)} placeholder={o.dflt} aria-label={o.key} onchange={(e) => commit(o, e.currentTarget.value)} onkeydown={(e) => onKey(e, o)} />
                {:else}
                  <input class="input in ro" value={o.cur} placeholder={o.type === 'table' || o.type === 'list' ? '' : o.dflt} readonly aria-label={o.key} />
                {/if}
                <span class="hp" use:tip={o.help}>{o.help}{#if d?.sent} <span class="app">· applying…</span>{/if}</span>
              </div>
            </div>
          {/each}
        </div>
      {/each}
    </div>
  {:else}
    <div class="muted">{list.loaded ? (list.error ? `The settings could not be read${list.error?.message ? `: ${list.error.message}` : '.'}` : 'No settings.') : 'Loading…'}</div>
  {/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 14px; }
  .b13 { font-size: 13px; }
  .prow { display: flex; align-items: center; gap: 10px; }
  .pt { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .hp2 { margin: 0; font-size: 12.5px; color: var(--color-neutral-500); }
  .cols { column-width: 400px; column-gap: 14px; }
  .sec { padding: 14px 16px; gap: 10px; break-inside: avoid; margin-bottom: 14px; }
  .st { font-size: 14px; font-weight: 500; }
  .fld { display: grid; grid-template-columns: 150px minmax(0, 1fr); gap: 12px; align-items: start; }
  .k { padding-top: 7px; overflow-wrap: anywhere; }
  .k code { font-size: 12px; color: var(--color-neutral-200); }
  .v { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .in { min-height: 32px; font-size: 13px; font-family: var(--font-mono, ui-monospace, monospace); }
  .ro { color: var(--color-neutral-300); }
  .hp { font-size: 11.5px; color: var(--color-neutral-500); display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
  .app { color: var(--color-accent-300); }
  .res { padding: 12px 14px; gap: 8px; }
  .res.bad { box-shadow: inset 0 0 0 1px var(--st-bad); }
  .rh { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 500; }
  .x { width: 26px; height: 26px; color: var(--color-neutral-400); }
  pre { margin: 0; font-size: 12px; white-space: pre-wrap; color: var(--color-neutral-300); font-family: var(--font-mono, ui-monospace, monospace); }
  .muted { font-size: 12px; color: var(--fg-3); }
</style>
