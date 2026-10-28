<script>
  // Users of the domain: the list on the left, the drawer on the right (facts, groups, the shares the user can reach). The share access matrix is READ
  // ONLY here: permissions are edited on the share itself (decision 4 of ); a row links to the share.
  import { poll, rows } from '../data.svelte.js';
  import { go } from '../route.svelte.js';
  import { takeSelection, setSelection } from '../select.svelte.js';
  import { openPlan, openCreate } from '../ui.svelte.js';
  import NewUser from '../forms/users/NewUser.svelte';
  import SetPassword from '../forms/users/SetPassword.svelte';
  import Membership from '../forms/users/Membership.svelte';
  import SshKeys from '../forms/ssh/SshKeys.svelte';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Split from '../ui/Split.svelte';
  import Drawer from '../ui/Drawer.svelte';
  import Kv from '../ui/Kv.svelte';
  import Chip from '../ui/Chip.svelte';

  const list = poll('/api/sys/users/list', 30000);
  const glist = poll('/api/sys/users/groups', 30000);
  const groupNames = $derived(rows(glist).map((r) => r[0]));
  let selName = $state('');
  let tab = $state('info');
  $effect(() => { const n = takeSelection('users'); if (n) selName = n; });

  // name, full name, enabled|disabled, groups (comma separated)
  const users = $derived(rows(list).map((r) => ({
    name: r[0], full: r[1] && r[1] !== '-' ? r[1] : '', enabled: r[2] === 'enabled',
    groups: (r[3] ?? '').split(',').map((g) => g.trim()).filter(Boolean),
  })));
  const sel = $derived(users.find((u) => u.name === selName));

  // share, level, via (reads every share ACL: only for the opened user)
  const acc = poll(() => (sel ? `/api/sys/users/access/${encodeURIComponent(sel.name)}` : ''), 30000);
  const reach = $derived(rows(acc).map((r) => ({ share: r[0], level: r[1], via: r[2] })));
  const isAdmin = $derived(sel?.name.toLowerCase() === 'administrator' && !!sel?.enabled);
  const reachColumns = [{ key: 'share', label: 'Share' }, { key: 'level', label: 'Level' }, { key: 'via', label: 'Through' }];
  const stateOf = (u) => (u.enabled ? 'active' : 'locked');
  const toShare = (s) => { setSelection('shares', s); go('/storage/bulk/shares'); };

  const columns = [
    { key: 'name', label: 'User' }, { key: 'full', label: 'Name', optional: true }, { key: 'groups', label: 'Groups', optional: true, value: (u) => u.groups.join(', ') },
    { key: 'state', label: 'State', value: (u) => stateOf(u) },
  ];
</script>

<PageHeader title="Users" crumb="Identity" sub="The accounts of the domain. Locking or deleting shows a plan first.">
  {#snippet actions()}
    <button class="btn" title="The SSH keys that may log in as adminuser" onclick={() => openCreate(SshKeys)}><i class="ph ph-key"></i>SSH keys</button>
    <button class="btn btn-primary" onclick={() => openCreate(NewUser)}><i class="ph ph-plus"></i>New user</button>
  {/snippet}
</PageHeader>

<PageState loading={!list.loaded} error={list.error?.message} hasData={list.data != null} empty={list.loaded && !users.length}
           emptyIcon="user" emptyTitle="No users" emptyText="The domain controller (dc1) may be down, or the storage is locked. Otherwise add the first user.">
  {#snippet emptyAction()}<button class="btn btn-primary" onclick={() => openCreate(NewUser)}><i class="ph ph-plus"></i>New user</button>{/snippet}
  <Split open={!!sel}>
    {#snippet list()}
      <div class="card" style="padding:0">
        <Table id="users" {columns} rows={users} key="name" selected={sel?.name} onrow={(u) => { selName = u.name; tab = 'info'; }}>
          {#snippet cell(u, col)}
            {#if col.key === 'name'}<b>{u.name}</b>
            {:else if col.key === 'full'}<span class="muted">{u.full}</span>
            {:else if col.key === 'groups'}<span class="tags">{#each u.groups as g}<Chip>{g}</Chip>{/each}</span>
            {:else}<span class="st"><span class="dot {u.enabled ? 'ok' : 'off'}"></span>{stateOf(u)}</span>{/if}
          {/snippet}
        </Table>
      </div>
    {/snippet}
    {#snippet side()}
      {#if sel}
        <Drawer title={sel.name} chip={sel.full} state={sel.enabled ? 'ok' : 'off'} stateLabel={stateOf(sel)} bind:tab onclose={() => (selName = '')}
                tabs={[{ id: 'info', label: 'Info' }, { id: 'access', label: 'Can reach' }]}>
          {#snippet children(t)}
            {#if t === 'access'}
              <Table id="reach" columns={reachColumns} rows={reach} key="share" loading={!acc.loaded} empty={acc.loaded ? (acc.error ? 'The access could not be read.' : 'No share is reachable.') : 'Loading…'}>
                {#snippet cell(r, col)}
                  {#if col.key === 'share'}<button class="link-btn" title="Permissions are edited on the share" onclick={() => toShare(r.share)}>{r.share}</button>
                  {:else if col.key === 'level'}<Chip>{r.level}</Chip>
                  {:else}<span class="muted">{r.via}</span>{/if}
                {/snippet}
              </Table>
              <p class="note">Read only. Change who may reach a share on the share itself (its Permissions tab).</p>
            {:else}
              <Kv items={[{ k: 'Account', v: sel.name }, { k: 'Full name', v: sel.full }, { k: 'State', v: stateOf(sel) }, { k: 'Groups', v: sel.groups.join(', ') }]} />
            {/if}
          {/snippet}
          {#snippet actions()}
            <button class="btn" onclick={() => openCreate(SetPassword, { user: sel.name })}><i class="ph ph-password"></i>Password</button>
            <button class="btn" onclick={() => openCreate(Membership, { subject: 'user', name: sel.name, have: sel.groups, options: groupNames })}><i class="ph ph-users-three"></i>Groups</button>
            <button class="btn btn-ghost" disabled={isAdmin} title={isAdmin ? 'Administrator cannot be locked' : sel.enabled ? 'Lock the account (shows the plan first)' : 'Unlock the account (shows the plan first)'}
              onclick={() => openPlan('users', [sel.name, sel.enabled ? 'lock' : 'unlock'], `${sel.enabled ? 'Lock' : 'Unlock'} ${sel.name}`)}><i class="ph {sel.enabled ? 'ph-lock' : 'ph-lock-open'}"></i>{sel.enabled ? 'Lock' : 'Unlock'}</button>
            <button class="btn btn-ghost danger" disabled={isAdmin} title={isAdmin ? 'Administrator cannot be deleted' : 'Delete the user (cannot be undone; you type the name)'}
              onclick={() => openPlan('users', [sel.name, 'user-delete'], `Delete ${sel.name}`)}><i class="ph ph-trash"></i>Delete</button>
          {/snippet}
        </Drawer>
      {/if}
    {/snippet}
  </Split>
</PageState>

<style>
  .muted { color: var(--fg-3); font-size: 12.5px; }
  .tags { display: flex; gap: 4px; flex-wrap: wrap; }
  .st { display: inline-flex; align-items: center; gap: 6px; }
  .danger { color: var(--bad); }
  .note { margin: 0; padding: 10px 16px; font-size: 12.5px; color: var(--fg-3); }
  .table { font-size: 12.5px; }
  .link-btn { all: unset; cursor: pointer; color: var(--accent); }
  .link-btn:hover { text-decoration: underline; }
</style>
