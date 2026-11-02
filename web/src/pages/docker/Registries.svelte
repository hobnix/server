<script>
  // Registries: the logins for private registries (ghcr.io) of the apps in Docker. hs sys docker registries reads, hs sys docker-registry plan|start
  // add|remove change. The token sits in the vault and reaches a pull for one command only; this page never shows it.
  import { poll, rows, refresh } from '../../data.svelte.js';
  import { openCreate, openPlan, jobRunning } from '../../ui.svelte.js';
  import Table from '../../shell/Table.svelte';
  import PageHeader from '../../shell/PageHeader.svelte';
  import PageState from '../../shell/PageState.svelte';
  import Banner from '../../ui/Banner.svelte';
  import Button from '../../ui/Button.svelte';
  import StatusDot from '../../ui/StatusDot.svelte';
  import RegistryForm from '../../forms/docker/RegistryForm.svelte';

  const PATH = '/api/sys/docker/registries';
  const list = poll(PATH, 15000);

  // host, user, state (ok|locked|missing), used_by (apps, comma; - when none)
  const items = $derived(rows(list).map((r) => ({ host: r[0], user: r[1], state: r[2], usedBy: r[3] === '-' ? '' : r[3] })));
  const locked = $derived(items.some((i) => i.state === 'locked'));
  const dot = (s) => (s === 'ok' ? 'ok' : s === 'locked' ? 'warn' : 'bad');
  const label = (s) => (s === 'ok' ? 'ready' : s === 'locked' ? 'vault closed' : 'token missing');

  const columns = [
    { key: 'host', label: 'Registry' },
    { key: 'user', label: 'User' },
    { key: 'state', label: 'Token' },
    { key: 'usedBy', label: 'Used by' },
    { key: 'act', label: '', sort: false, align: 'right' },
  ];
  const add = () => openCreate(RegistryForm, { ondone: () => refresh([PATH]) });
</script>

<PageHeader title="Registries" crumb="Docker" sub="Logins for private image registries such as ghcr.io." />

<PageState loading={!list.loaded} error={list.error?.message} hasData={list.data != null}
           empty={list.loaded && !items.length && !list.error} emptyIcon="key" emptyTitle="No registry login" emptyText="Apps pull public images without a login. Add one for ghcr.io or another private registry."
           retry={() => refresh([PATH])}>
  {#if locked}
    <Banner tone="warn">The vault is closed, so pulls and rebuilds of apps that use a stored token are refused. Open it in a terminal: <code>hs vault open</code>.</Banner>
  {/if}
  <div class="toolbar"><Button size="sm" icon="plus" onclick={add}>Add registry</Button></div>
  <div class="card" style="padding:0">
    <Table id="docker-registries" {columns} rows={items} key="host" loading={!list.loaded} empty="No registry logins.">
      {#snippet cell(i, col)}
        {#if col.key === 'host'}{i.host}
        {:else if col.key === 'user'}{i.user}
        {:else if col.key === 'state'}<StatusDot state={dot(i.state)} label={label(i.state)} />
        {:else if col.key === 'usedBy'}{i.usedBy || '–'}
        {:else}
          <Button size="sm" variant="danger" busy={jobRunning('docker-registry', ['remove', i.host])} busyLabel="Removing…" tooltip="Remove this login" onclick={() => openPlan('docker-registry', ['remove', i.host], `remove ${i.host}`)}>Remove</Button>
        {/if}
      {/snippet}
    </Table>
  </div>
</PageState>

<style>
  .toolbar { display: flex; gap: 8px; margin-bottom: 12px; }
</style>
