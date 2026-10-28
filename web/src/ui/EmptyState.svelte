<script>
  // One sentence and the one action that creates the first object; never an empty table. The icon sits in a round tile (the only round thing
  // in the design). `tone`: '' | 'info'. The action goes in the `action` snippet (usually one primary Button).
  //   <EmptyState icon="folders" title="No shares yet" text="Create the first one.">{#snippet action()}<button class="btn btn-primary">New share</button>{/snippet}</EmptyState>
  let { icon = 'tray', title = '', text = '', tone = '', action } = $props();
</script>

<div class="gempty">
  <div class="tile2 {tone}"><i class="ph ph-{icon}" style="font-size:20px"></i></div>
  {#if title}<b>{title}</b>{/if}
  {#if text}<p>{text}</p>{/if}
  {@render action?.()}
</div>

<style>
  .gempty { display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 48px 20px; text-align: center; }
  .tile2 { width: 44px; height: 44px; border-radius: 50%; display: grid; place-items: center; background: var(--panel-3); color: var(--fg-2); }
  .tile2.info { background: color-mix(in oklch, var(--info) 18%, transparent); color: var(--info-ink); }
  b { font-size: 15px; font-weight: 600; }
  p { margin: 0; max-width: 440px; color: var(--fg-3); }
</style>
