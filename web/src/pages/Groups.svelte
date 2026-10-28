<script>
  // Groups of the domain: list on the left, drawer on the right (members, the shares the group is entered on). The share access is READ ONLY here:
  // permissions are edited on the share itself (decision 4 of ); a row links to the share.
  import { poll, rows } from '../data.svelte.js';
  import { go } from '../route.svelte.js';
  import { takeSelection, setSelection } from '../select.svelte.js';
  import { openPlan, openCreate } from '../ui.svelte.js';
  import NewGroup from '../forms/users/NewGroup.svelte';
  import Membership from '../forms/users/Membership.svelte';
  import EditGroup from '../forms/users/EditGroup.svelte';
  import GroupShares from './identity/GroupShares.svelte';
  import Table from '../shell/Table.svelte';
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Split from '../ui/Split.svelte';
  import Drawer from '../ui/Drawer.svelte';
  import Kv from '../ui/Kv.svelte';
  import Chip from '../ui/Chip.svelte';

  const list = poll('/api/sys/users/groups', 30000);
  let selName = $state('');
  let tab = $state('info');
  $effect(() => { const n = takeSelection('groups'); if (n) selName = n; });

  const ulist = poll('/api/sys/users/list', 30000);
  const userNames = $derived(rows(ulist).map((r) => r[0]));
  const builtin = (n) => /^(domain (users|admins|guests|computers|controllers)|administrators|schema admins|enterprise admins)$/i.test(n);
  // name, members (comma separated)
  const groups = $derived(rows(list).map((r) => ({ name: r[0], members: (r[1] ?? '').split(',').map((m) => m.trim()).filter(Boolean) })));
  const sel = $derived(groups.find((g) => g.name === selName));

  // share, level, via (the entries made for the group itself)
  const acc = poll(() => (sel ? `/api/sys/users/group-access/${encodeURIComponent(sel.name)}` : ''), 30000);
  const reach = $derived(rows(acc).map((r) => ({ share: r[0], level: r[1], via: r[2] })));
  // field, value of the opened group ("-" = empty)
  const det = poll(() => (sel ? `/api/sys/users/group-details/${encodeURIComponent(sel.name)}` : ''), 30000);
  const descr = $derived((() => { const v = rows(det).find((r) => r[0] === 'description')?.[1]; return v && v !== '-' ? v : ''; })());
  const reachColumns =[{ key: 'share', label: 'Share' }, { key: 'level', label: 'Level' }, { key: 'via', label: 'Through' }];
  const toShare = (s) => { setSelection('shares', s); go('/storage/bulk/shares'); };

  const columns = [
    { key: 'name', label: 'Group' }, { key: 'count', label: 'Members', sort: 'num', align: 'right', value: (g) => g.members.length },
    { key: 'members', label: 'Who', optional: true, value: (g) => g.members.join(', ') }, { key: 'shares', label: 'Shares', sort: false, optional: true },
  ];
</script>

<PageHeader title="Groups" crumb="Identity" sub="Who is in which group, and which shares a group is entered on.">
  {#snippet actions()}
    <button class="btn" title="Make the file server forget cached users and groups" onclick={() => openPlan('users', ['all', 'flush'], 'Flush caches')}><i class="ph ph-arrows-clockwise"></i>Flush caches</button>
    <button class="btn btn-primary" onclick={() => openCreate(NewGroup, { existing: groups.map((g) => g.name) })}><i class="ph ph-plus"></i>New group</button>
  {/snippet}
</PageHeader>

<PageState loading={!list.loaded} error={list.error?.message} hasData={list.data != null} empty={list.loaded && !groups.length}
           emptyIcon="users-four" emptyTitle="No groups" emptyText="The domain controller (dc1) may be down, or the storage is locked. Otherwise add the first group.">
  {#snippet emptyAction()}<button class="btn btn-primary" onclick={() => openCreate(NewGroup, { existing: [] })}><i class="ph ph-plus"></i>New group</button>{/snippet}
  <Split open={!!sel}>
    {#snippet list()}
      <div class="card" style="padding:0">
        <Table id="groups" {columns} rows={groups} key="name" selected={sel?.name} onrow={(g) => { selName = g.name; tab = 'info'; }}>
          {#snippet cell(g, col)}
            {#if col.key === 'name'}<b>{g.name}</b>
            {:else if col.key === 'count'}{g.members.length}
            {:else if col.key === 'members'}<span class="muted">{g.members.join(', ') || '—'}</span>
            {:else}<span class="muted"><GroupShares name={g.name} /></span>{/if}
          {/snippet}
        </Table>
      </div>
    {/snippet}
    {#snippet side()}
      {#if sel}
        <Drawer title={sel.name} chip={builtin(sel.name) ? 'built in' : ''} bind:tab onclose={() => (selName = '')} tabs={[{ id: 'info', label: 'Members' }, { id: 'access', label: 'Shares' }]}>
          {#snippet children(t)}
            {#if t === 'access'}
              <Table id="reach" columns={reachColumns} rows={reach} key="share" loading={!acc.loaded} empty={acc.loaded ? (acc.error ? 'The access could not be read.' : 'The group is on no share.') : 'Loading…'}>
                {#snippet cell(r, col)}
                  {#if col.key === 'share'}<button class="link-btn" title="Permissions are edited on the share" onclick={() => toShare(r.share)}>{r.share}</button>
                  {:else if col.key === 'level'}<Chip>{r.level}</Chip>
                  {:else}<span class="muted">{r.via}</span>{/if}
                {/snippet}
              </Table>
              <p class="note">Read only. Change who may reach a share on the share itself (its Permissions tab).</p>
            {:else}
              <Kv cols={1} items={[{ k: 'Description', v: descr }, { k: 'Members', v: sel.members.join(', ') }]} />
            {/if}
          {/snippet}
          {#snippet actions()}
            <button class="btn" disabled={builtin(sel.name)} title={builtin(sel.name) ? 'A built-in group cannot be edited' : 'Change the description'}
              onclick={() => openCreate(EditGroup, { name: sel.name })}><i class="ph ph-pencil-simple"></i>Edit</button>
            <button class="btn" disabled={sel.name.toLowerCase() === 'domain users'} title="Choose the members"
              onclick={() => openCreate(Membership, { subject: 'group', name: sel.name, have: sel.members, options: userNames })}><i class="ph ph-user-plus"></i>Members</button>
            <button class="btn btn-ghost danger" disabled={builtin(sel.name)} title={builtin(sel.name) ? 'A built-in group cannot be deleted' : 'Delete the group (cannot be undone; you type the name)'}
              onclick={() => openPlan('users', [sel.name, 'group-delete'], `Delete ${sel.name}`)}><i class="ph ph-trash"></i>Delete</button>
          {/snippet}
        </Drawer>
      {/if}
    {/snippet}
  </Split>
</PageState>

<style>
  .muted { color: var(--fg-3); font-size: 12.5px; }
  .danger { color: var(--bad); }
  .note { margin: 0; padding: 10px 16px; font-size: 12.5px; color: var(--fg-3); }
  .table { font-size: 12.5px; }
  .link-btn { all: unset; cursor: pointer; color: var(--accent); }
  .link-btn:hover { text-decoration: underline; }
</style>
