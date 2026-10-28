<script>
  // The page of an extension package at /extensions/<name>: the package's own [web.page] declaration (capabilities/<name>/capability.toml; the server
  // sends it in the session answer, features.extensions, only while the package is on), drawn by GenericPage. The declaration names its reads by their
  // words ("list"); here they become the paths of the generic read API (/api/sys/ext/<name>/list).
  import GenericPage from '../shell/GenericPage.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import { route, go } from '../route.svelte.js';
  import { ui } from '../ui.svelte.js';
  import PcForm from '../forms/ops/PcForm.svelte';
  import PosterForm from '../forms/ops/PosterForm.svelte';
  import PassthroughForm from '../forms/ops/PassthroughForm.svelte';

  // the dialogs a declaration may name (`form = "PcForm"`): a closed list, a package cannot bring its own code
  const forms = { PcForm, PosterForm, PassthroughForm };

  const name = $derived(route.path.split('/')[2] ?? '');
  const page = $derived((ui.features.extensions ?? []).find((p) => p.name === name));

  const path = (n, words) => `/api/sys/ext/${n}/${String(words).split(' ').map(encodeURIComponent).join('/')}`;
  function resolve(node, n) {
    if (Array.isArray(node)) return node.map((v) => resolve(v, n));
    if (node && typeof node === 'object') {
      const o = {};
      for (const [k, v] of Object.entries(node)) o[k] = k === 'read' && typeof v === 'string' ? path(n, v) : resolve(v, n);
      return o;
    }
    return node;
  }
  const spec = $derived(page ? resolve(page, page.name) : null);
</script>

{#if spec}
  {#key name}<GenericPage {spec} {forms} />{/key}
{:else}
  <div class="card"><EmptyState tone="info" icon="power" title="This extension is switched off" text="It is not part of this server's configuration, so there is nothing to show. Switch it on with hs ext enable, or in Settings.">
    {#snippet action()}<button class="btn" onclick={() => go('/settings')}><i class="ph ph-sliders"></i>Open Settings</button>{/snippet}
  </EmptyState></div>
{/if}
