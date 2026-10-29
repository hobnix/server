<script>
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows } from '../data.svelte.js';
  import { bytes } from '../format.js';
  import { openPlan } from '../ui.svelte.js';
  import { go } from '../route.svelte.js';
  import Table from '../shell/Table.svelte';
  import UsageBar from '../shell/UsageBar.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import { StatusDot, Banner } from '../ui/index.js';

  let { deck } = $props();
  const list = poll('/api/sys/vault/list', 30000);
  const status = poll('/api/sys/status', 15000);
  const usage = poll('/api/sys/vault/usage', 30000);
  const uses = poll('/api/sys/vault/uses', 60000);

  // `sys vault usage`: key/value lines (state, device, size, used, free in bytes, header-backup-days); `sys vault uses`: item name, who uses it
  const u = $derived(Object.fromEntries(rows(usage).map((r) => [r[0], r[1]])));
  const usedBy = $derived(Object.fromEntries(rows(uses).map((r) => [r[0], r[1]])));
  const by = (name) => {
    const v = usedBy[name.replace(/ \(.*$/, '')];
    return v && v !== '-' ? v : '–';
  };
  const size = $derived(Number(u.size));
  const used = $derived(Number(u.used));
  const hasUsed = $derived(u.state === 'open' && u.used != null && size > 0);

  // name, kind (secret|folder), state (in vault|closed|not moved|not mounted|-)
  const items = $derived(rows(list).map((r) => ({ name: r[0], kind: r[1], state: r[2] })));
  const locked = $derived(!!deck?.data?.locked || rows(status).some((r) => r[0] === 'encryption' && r[1] === 'locked'));
  const closed = $derived(items.some((i) => i.state === 'closed'));
  const dot = (s) => (s === 'in vault' ? 'ok' : s === 'closed' || s === '-' ? 'off' : 'warn');
  const n = $derived(items.length);
  const title = $derived(!list.loaded ? 'Loading…' : list.error && !n ? (locked ? 'Locked · items unavailable' : 'The vault could not be read') : closed || locked ? 'Locked · items unavailable' : `Open · ${n} item${n === 1 ? '' : 's'}`);
  const vstate = $derived(!list.loaded ? 'off' : closed || locked || (list.error && !n) ? 'warn' : 'ok');

  const columns = [
    { key: 'name', label: 'Item' }, { key: 'kind', label: 'Kind', optional: true }, { key: 'by', label: 'Used by', value: (i) => by(i.name) }, { key: 'state', label: 'State' },
  ];
</script>

<PageHeader title="Vault" crumb="Storage" sub="Secrets for the server's own services, in a LUKS partition of their own.">
  {#snippet actions()}
    <button class="btn" disabled={u.state !== 'open'} use:tip={'Save the LUKS header outside the vault'} onclick={() => openPlan('secrets', ['header-backup'], 'Save the LUKS header')}><i class="ph ph-floppy-disk"></i>Save header</button>
    <button class="btn" disabled={u.state !== 'open'} use:tip={'Move the usual secrets into the vault'} onclick={() => openPlan('secrets', ['move'], 'Move secrets into the vault')}><i class="ph ph-arrow-square-in"></i>Move secrets in</button>
    <button class="btn" use:tip={'Root-only permissions on the secret files'} onclick={() => openPlan('secrets', ['secrets-fix'], 'Fix the permissions of the secrets')}><i class="ph ph-shield-check"></i>Fix permissions</button>
    <button class="btn" disabled={u.state !== 'open'} use:tip={'Close the vault (refused while something uses it)'} onclick={() => openPlan('secrets', ['close'], 'Close the vault')}><i class="ph ph-lock-simple"></i>Close…</button>
  {/snippet}
</PageHeader>

<div class="card xh hero">
  <i class="ph ph-vault big-i {vstate}"></i>
  <div class="tx">
    <div class="big">{title}</div>
    <div class="desc">A 10 GiB LUKS partition on the system disk, opened with the same passphrase as the pools. Not part of the host backup snapshot.</div>
    {#if u.device}<div class="note">on <code>{u.device}</code>{#if u['header-backup-days'] != null} · LUKS header saved {u['header-backup-days']} day{u['header-backup-days'] === '1' ? '' : 's'} ago{/if}</div>{/if}
  </div>
  <div class="space">
    <div class="note">Space</div>
    {#if hasUsed}<UsageBar {used} {size} />
    {:else}<span class="note">{size > 0 ? `${bytes(size)} partition${u.state === 'closed' ? ' · usage is only known while it is open' : ''}` : usage.loaded ? 'not available' : 'Loading…'}</span>{/if}
  </div>
</div>
{#if closed || locked}<Banner tone="warn">The vault is closed because the storage is locked. Unlock it on the <button class="link-btn" onclick={() => go('/storage/encryption')}>Encryption</button> page; locked is a normal state after a boot.</Banner>{/if}

<div class="card sect">
  <div class="sh"><b>Vault items</b><span class="note">values are never shown</span></div>
  <div class="scrollx">
    <Table id="vault" {columns} rows={items} key="name" compact loading={!list.loaded}
           empty={list.error ? 'The vault could not be read (is the storage locked?).' : 'No items.'}>
      {#snippet cell(i, col)}
        {#if col.key === 'name'}<code>{i.name}</code>
        {:else if col.key === 'kind'}<span class="mute">{i.kind}</span>
        {:else if col.key === 'by'}<span class="mute">{by(i.name)}</span>
        {:else}<StatusDot state={dot(i.state)} label={i.state} />{/if}
      {/snippet}
    </Table>
  </div>
  <div class="note">Making the vault (<code>hs vault init</code>, it erases a partition) and moving a whole folder in (<code>hs vault bind</code>) stay in the terminal; the vault is opened from the Encryption page.</div>
  <div class="note">{uses.error ? 'Who uses an item could not be read.' : 'Who uses an item comes from a fixed list of the server\'s own services; an item that list does not know shows a dash.'}</div>
</div>

<style>
  .hero { flex-direction: row; align-items: center; gap: 18px; padding: 16px 18px; flex-wrap: wrap; margin-bottom: 14px; }
  .big-i { font-size: 30px; color: var(--off); }
  .big-i.ok { color: var(--ok); }
  .big-i.warn { color: var(--warn); }
  .tx { flex: 1 1 320px; }
  .big { font-size: 18px; font-weight: 600; }
  .desc { color: var(--fg-2); }
  .space { flex: 0 1 300px; display: flex; flex-direction: column; gap: 6px; }
  .sect { padding: 12px 14px; gap: 8px; margin-top: 14px; }
  .sh { display: flex; align-items: baseline; gap: 8px; }
  .scrollx { overflow-x: auto; }
  .mute { color: var(--fg-2); }
  code { font-size: 12px; }
  .note { font-size: 12px; color: var(--fg-3); }
</style>
