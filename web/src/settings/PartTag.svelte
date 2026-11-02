<script>
  // The tag of one part (off / on / running / rebuild needed) for lists. It reads the `running` row of the part's status read only when the part is
  // on and has one (layout.caps[name].status); the capability page's header does the same with the StatusPanel's row.
  import StatusDot from '../ui/StatusDot.svelte';
  import { tip } from '../ui/tooltip.svelte.js';
  import { poll, rows } from '../data.svelte.js';
  import layout from './layout.gen.json';
  import { partTag } from './tag.js';

  let { part } = $props();
  const read = $derived(part.on ? layout.caps[part.name]?.status ?? '' : '');
  const st = poll(() => (read ? `/api/sys/${read.split(/\s+/).join('/')}` : ''), 60000);
  const running = $derived(rows(st).find((r) => r[0] === 'running')?.[1] ?? '');
  const tag = $derived(partTag(part, running));
</script>

<span use:tip={part.nix ? 'A part with a NixOS module changes at the next hs rebuild' : undefined}><StatusDot state={tag.state} label={tag.label} /></span>
