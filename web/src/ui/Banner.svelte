<script>
  // A line of advice above a page or a card. `tone`: warn (amber: locked, old data, almost full) | bad (red: real failure) | info (blue) | ok (green).
  // The text goes in the default snippet, an optional action (a button or link) in `action`; `icon` overrides the phosphor icon of the tone.
  //   <Banner tone="warn">Storage is locked.{#snippet action()}<button class="btn sm">Unlock</button>{/snippet}</Banner>
  let { tone = 'warn', icon = '', children, action } = $props();
  const icons = { warn: 'warning', bad: 'warning-octagon', info: 'info', ok: 'check-circle' };
</script>

<div class="banner {tone}" role={tone === 'bad' ? 'alert' : 'status'}>
  <i class="ph ph-{icon || icons[tone] || 'info'}" style="font-size:17px"></i>
  <div class="tx">{@render children?.()}</div>
  {#if action}<div class="act">{@render action()}</div>{/if}
</div>

<style>
  .banner { --c: var(--warn); display: flex; align-items: center; gap: 12px; flex-wrap: wrap; padding: 10px 14px; border: 1px solid color-mix(in oklch, var(--c) 45%, var(--line)); border-radius: var(--r); background: color-mix(in oklch, var(--c) 11%, var(--panel)); }
  .banner.bad { --c: var(--bad); }
  .banner.info { --c: var(--info); }
  .banner.ok { --c: var(--ok); }
  i { flex: none; color: var(--c); }
  .tx { flex: 1; min-width: 200px; }
  .act { display: flex; gap: 8px; align-items: center; }
</style>
