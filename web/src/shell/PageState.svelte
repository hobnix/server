<script>
  import { tip } from '../ui/tooltip.svelte.js';
  // The common states of a page's DATA, written once. A page hands in what its reads say; this component decides what to show:
  //   loading (no data yet)       -> skeleton blocks
  //   error, no data              -> red banner with Try again
  //   error, data kept            -> amber banner "could not refresh" with the age + Try again, and the OLD data stays visible
  //   empty                       -> EmptyState: one sentence and the one action that creates the first object (never an empty table)
  //   otherwise                   -> the page content (default snippet)
  // The shell frame (PageFrame.svelte) already handles: storage locked, part switched off, node unreachable. A page does not repeat those.
  //
  //   const ct = poll('/api/sys/ct/list', 5000);
  //   <PageState loading={!ct.loaded} error={ct.error?.message} hasData={ct.data != null} empty={!rows(ct).length}
  //              emptyIcon="cube" emptyTitle="No instances yet" emptyText="Create the first one." retry={() => refresh(readsFor(route.path))}>
  //     ...the table...
  //     {#snippet emptyAction()}<button class="btn btn-primary">New instance</button>{/snippet}
  //   </PageState>
  import Banner from '../ui/Banner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import Skeleton from '../ui/Skeleton.svelte';

  let {
    loading = false, error = '', hasData = false, empty = false, age = null, retry = null,
    emptyIcon = 'tray', emptyTitle = 'Nothing here yet', emptyText = '', emptyAction, skeletonLines = 6, children,
  } = $props();

  const ageTxt = (s) => (s == null ? '' : s < 90 ? `${Math.round(s)} s` : s < 5400 ? `${Math.round(s / 60)} min` : `${Math.round(s / 3600)} h`);
</script>

{#if loading && !hasData}
  <div class="card"><Skeleton lines={skeletonLines} height={14} gap={14} /></div>
{:else if error && !hasData}
  <Banner tone="bad">Could not read this page: {error}
    {#snippet action()}{#if retry}<button use:tip={'Read the page again'} class="btn sm" onclick={retry}><i class="ph ph-arrow-clockwise"></i>Try again</button>{/if}{/snippet}
  </Banner>
{:else}
  {#if error}
    <Banner tone="warn">Could not refresh: {error}. Showing the data from {age != null ? `${ageTxt(age)} ago` : 'before'}.
      {#snippet action()}{#if retry}<button use:tip={'Read the page again'} class="btn sm" onclick={retry}><i class="ph ph-arrow-clockwise"></i>Try again</button>{/if}{/snippet}
    </Banner>
  {/if}
  {#if empty}
    <div class="card"><EmptyState icon={emptyIcon} title={emptyTitle} text={emptyText} action={emptyAction} /></div>
  {:else}
    {@render children?.()}
  {/if}
{/if}
