<script>
  // The ISO library (issue #259): install images for virtual machines. Reads `hs sys iso list`; adding is the create dialog (forms/instances/IsoAdd.svelte,
  // a background job), removing is a plan that asks for the name (hs sys iso plan remove <name>).
  import PageHeader from '../shell/PageHeader.svelte';
  import PageState from '../shell/PageState.svelte';
  import Table from '../shell/Table.svelte';
  import Button from '../ui/Button.svelte';
  import Chip from '../ui/Chip.svelte';
  import { poll, rows, refresh } from '../data.svelte.js';
  import { openCreate, openPlan, jobRunning } from '../ui.svelte.js';
  import { bytes } from '../format.js';
  import IsoAdd from '../forms/instances/IsoAdd.svelte';

  const columns = [
    { key: 'name', label: 'Name' },
    { key: 'size', label: 'Size', sort: 'num', value: (i) => i.size },
    { key: 'sum', label: 'Checksum', optional: true },
    { key: 'checked', label: 'Checked', value: (i) => (i.checked ? 'yes' : 'no') },
    { key: 'source', label: 'Source', optional: true },
    { key: 'used', label: 'Used by' },
    { key: 'actions', label: '', sort: false, align: 'right' },
  ];

  const lst = poll('/api/sys/iso/list', 10000, 'iso-list');
  // name, bytes, algo, checksum, checked (yes|no), source, added, used by (instances or -)
  const images = $derived(rows(lst).map((r) => ({ name: r[0], size: Number(r[1]), algo: r[2], hash: r[3], checked: r[4] === 'yes', source: r[5], added: r[6], used: r[7] && r[7] !== '-' ? r[7] : '' })));
</script>

<PageHeader title="ISO images" crumb="Instances" sub="Install images for virtual machines. A checksum is verified before an image can be used.">
  {#snippet actions()}
    <Button variant="primary" tooltip={'Add an image from a file on this server or from a URL'} busy={jobRunning('iso')} onclick={() => openCreate(IsoAdd)}><i class="ph ph-plus"></i>Add image</Button>
  {/snippet}
</PageHeader>

<PageState loading={!lst.loaded} error={lst.error?.message} hasData={lst.data != null} empty={lst.loaded && !images.length && !lst.error}
           emptyIcon="disc" emptyTitle="No images yet" emptyText="Add an installer image (an .iso file) from a file on this server or from a URL. It is checked against the checksum from the download page."
           retry={() => refresh(['/api/sys/iso/list'])}>
  {#snippet emptyAction()}<Button variant="primary" tooltip={'Add an image from a file on this server or from a URL'} onclick={() => openCreate(IsoAdd)}><i class="ph ph-plus"></i>Add image</Button>{/snippet}
  <div class="card" style="padding:0">
    <Table id="iso" {columns} rows={images} key="name" loading={!lst.loaded} empty="No images.">
      {#snippet cell(i, col)}
        {#if col.key === 'name'}<span class="nm"><i class="ph ph-disc"></i>{i.name}</span>
        {:else if col.key === 'size'}{bytes(i.size)}
        {:else if col.key === 'sum'}<span class="mono" title="{i.algo}:{i.hash}">{i.algo}:{i.hash.slice(0, 12)}…</span>
        {:else if col.key === 'checked'}{#if i.checked}<Chip title="The checksum matched the one that was given">verified</Chip>{:else}<Chip tone="warn" title="No checksum was given: compare the one shown with the download page">not checked</Chip>{/if}
        {:else if col.key === 'source'}<span class="src" title={i.source}>{i.source}</span>
        {:else if col.key === 'used'}{i.used || '–'}
        {:else}<Button variant="ghost" class="btn-icon iso-rm" icon="trash" aria-label="Remove {i.name}" tooltip={i.used ? `Attached to ${i.used}` : `Remove ${i.name} from the library`} disabled={!!i.used} busy={jobRunning('iso', ['remove', i.name])} onclick={() => openPlan('iso', ['remove', i.name], 'Remove ' + i.name)}></Button>{/if}
      {/snippet}
    </Table>
  </div>
  <div class="hint">Folder: set with <code>isoDir</code> on the Incus settings page (default /var/lib/hs/iso). <code>hs iso</code> does the same on the console.</div>
</PageState>

<style>
  .nm { display: inline-flex; align-items: center; gap: 8px; }
  .mono { font-family: var(--mono); font-size: 12px; }
  .src { display: inline-block; max-width: 280px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--fg-3); vertical-align: bottom; }
  .hint { font-size: 12px; color: var(--fg-3); margin-top: 10px; }
  :global(.btn.iso-rm) { width: 26px; height: 26px; }
</style>
