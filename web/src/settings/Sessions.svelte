<script>
  // The web sessions (Settings > Users and access): who is signed in, from where, and a way to end one or all the others (#504).
  // The server sends id, user, realm, created, seen, ip, ua, current; the id is a short name, never the cookie.
  import { onMount } from 'svelte';
  import { sessions, endSession, endOtherSessions } from '../api.js';
  import Button from '../ui/Button.svelte';
  import Banner from '../ui/Banner.svelte';
  import Table from '../shell/Table.svelte';

  let list = $state({ rows: [], loaded: false, error: '' });
  let message = $state('');

  const columns = [
    { key: 'user', label: 'User' },
    { key: 'ua', label: 'Browser' },
    { key: 'ip', label: 'From' },
    { key: 'created', label: 'Signed in', sort: 'num' },
    { key: 'seen', label: 'Last seen', sort: 'num' },
    { key: 'act', label: '', sort: false, align: 'right' },
  ];

  const when = (t) => new Date(t * 1000).toLocaleString();

  async function load() {
    try {
      list = { rows: (await sessions()).sessions, loaded: true, error: '' };
    } catch (e) {
      list = { rows: [], loaded: true, error: e.message };
    }
  }
  onMount(load);

  async function end(r) {
    message = '';
    try {
      await endSession(r.id);
      if (r.current) { location.reload(); return; }      // this browser is signed out now: the app shows the sign-in page
      await load();
    } catch (e) { message = e.message; }
  }

  async function endOthers() {
    message = '';
    try {
      const d = await endOtherSessions();
      message = d.ended === 1 ? 'Signed out 1 other session.' : `Signed out ${d.ended} other sessions.`;
      await load();
    } catch (e) { message = e.message; }
  }
</script>

<div class="card sec" id="sessions">
  <div class="st">Sessions</div>
  <p class="hp2">Everybody signed in to this web interface. A session ends by itself after 12 hours. Changing the password of the local admin ends its sessions.</p>
  {#if list.error}<Banner tone="warn">The sessions could not be read: {list.error}</Banner>{/if}
  <Table id="web-sessions" {columns} rows={list.rows} key="id" sort={{ key: 'seen', dir: 'desc' }} loading={!list.loaded} empty="No sessions.">
    {#snippet cell(r, col)}
      {#if col.key === 'user'}{r.user}{#if r.current} <span class="tag tag-accent">this browser</span>{/if}
      {:else if col.key === 'created' || col.key === 'seen'}{when(r[col.key])}
      {:else if col.key === 'act'}<Button size="sm" tooltip={r.current ? 'Sign out this browser' : 'End this session'} onclick={() => end(r)}>Sign out</Button>
      {:else}{r[col.key] || '–'}{/if}
    {/snippet}
  </Table>
  <div class="acts">
    <Button size="sm" tooltip={'End every session except this browser'} disabled={list.rows.length < 2} onclick={endOthers}>Sign out all other sessions</Button>
  </div>
  {#if message}<p class="hp2" role="status">{message}</p>{/if}
</div>

<style>
  .sec { padding: 14px 16px; gap: 10px; }
  .st { font-size: 14px; font-weight: 500; }
  .hp2 { margin: 0; font-size: 12.5px; color: var(--fg-3); }
  .acts { display: flex; gap: 8px; flex-wrap: wrap; }
</style>
