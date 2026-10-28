<script>
  // Small mono label. `kind`: '' (plain chip: a type, a count word), 'strong' = high contrast (over the halftone), 'out' = pill "outside this server" (blue outline), 'in' = pill "this server".
  //   <Chip>zfs</Chip>   <Chip kind="out">outside</Chip>   <Chip kind="in">this server</Chip>
  let { kind = '', children } = $props();
</script>

<span class="chip {kind}">{@render children?.()}</span>

<style>
  .chip { display: inline-block; font: 500 10.5px var(--mono); text-transform: uppercase; letter-spacing: 0.06em; padding: 1px 6px; border: 1px solid var(--line-2); border-radius: var(--r); color: var(--fg-3); white-space: nowrap; }
  /* readable on top of the halftone: full text colour on the panel, so the dots do not show through */
  .strong { color: var(--fg); background: var(--panel); border-color: var(--fg-3); }
  .out { border-color: color-mix(in oklch, var(--info) 55%, var(--line)); color: var(--info-ink); }
</style>
