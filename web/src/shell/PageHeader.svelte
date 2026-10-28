<script>
  // The head of a page: breadcrumb, title (h1), optional subtitle and the page's actions on the right. Phase-2 pages start with this.
  //   <PageHeader title="Disks" crumb="Storage" sub="Every disk of this server."> {#snippet actions()}<button class="btn btn-primary">Add disks</button>{/snippet} </PageHeader>
  import { tr } from "../i18n.js";
  let { title = '', crumb = '', sub = '', actions } = $props();
</script>

<div class="phead">
  <div class="tx">
    {#if crumb}<div class="crumb">{tr(crumb)}</div>{/if}
    <h1>{tr(title)}</h1>
    {#if sub}<p class="sub">{sub}</p>{/if}
  </div>
  {#if actions}<div class="acts">{@render actions()}</div>{/if}
</div>

<style>
  .phead { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 8px; }
  .crumb { font: 12px var(--mono); color: var(--fg-3); margin-bottom: 6px; }
  h1 { margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.03em; }
  .sub { margin: 4px 0 0; color: var(--fg-2); }
  .acts { display: flex; gap: 8px; flex-wrap: wrap; }
  @media (max-width: 860px) { h1 { font-size: 22px; } }
</style>
