<script>
  // Grey blocks while a page loads. `lines` blocks of `width` (css length or %), the last one shorter; `height` in px for one tall block.
  //   <Skeleton lines={4} />   <Skeleton height={120} />
  let { lines = 3, width = '100%', height = 12, gap = 10 } = $props();
</script>

<div class="skg" style:gap="{gap}px" aria-busy="true" aria-label="Loading">
  {#each Array(lines) as _, i}
    <div class="sk" style:height="{height}px" style:width={i === lines - 1 && lines > 1 ? '60%' : width}></div>
  {/each}
</div>

<style>
  .skg { display: flex; flex-direction: column; }
  .sk { border-radius: var(--r); background: linear-gradient(90deg, var(--panel-2), var(--panel-3), var(--panel-2)); background-size: 200% 100%; animation: sk 1.4s linear infinite; }
  @keyframes sk { to { background-position: -200% 0; } }
  @media (prefers-reduced-motion: reduce) { .sk { animation: none; } }
</style>
