<script>
  import { poll, rows } from '../../data.svelte.js';

  let { name } = $props();
  // share, level, via (the entries made for the group itself)
  const acc = poll(() => `/api/sys/users/group-access/${encodeURIComponent(name)}`, 30000);
  const text = $derived(rows(acc).map((r) => `${r[0]} (${r[1]})`).join(', '));
</script>

{acc.loaded ? (text || '—') : ''}
