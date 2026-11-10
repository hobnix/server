<script>
  import Button from '../../ui/Button.svelte';
  // New instance: `hs sys ct plan|start <name> create [--type container|docker|vm] [--ram MB] [--cpu N] [--disk GB] [--address ip] [--profile name] [--pool name]
  // [--iso name.iso] [--bind kind:name:/path[:ro] ...]`. One guided flow for every kind (issue #258): the steps are shared components (steps/), the plan on the
  // right is live from the first step, and Start is enabled as soon as the plan allows it. Steps: name and kind, resources, where the disk lives, the install
  // image (virtual machines only), network and storage.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import StepBasics from './steps/StepBasics.svelte';
  import StepResources from './steps/StepResources.svelte';
  import StepPlacement from './steps/StepPlacement.svelte';
  import StepMedia from './steps/StepMedia.svelte';
  import StepNetwork from './steps/StepNetwork.svelte';

  let { ondone = () => {} } = $props();
  let name = $state('');
  let type = $state('container');
  let ram = $state('');
  let cpu = $state('');
  let disk = $state('');
  let pool = $state('');
  let iso = $state('');
  let address = $state('');
  let profile = $state('');
  // bindings: storage attached once the instance runs (id keeps the rows apart while one is removed)
  let binds = $state([]);
  let step = $state(0);

  const steps = $derived([
    { id: 'basics', label: 'Name and kind' },
    { id: 'resources', label: 'Resources' },
    { id: 'placement', label: 'Disk' },
    ...(type === 'vm' ? [{ id: 'media', label: 'Install image' }] : []),
    { id: 'network', label: 'Network and storage' },
  ]);
  const cur = $derived(steps[Math.min(step, steps.length - 1)].id);
  const last = $derived(step >= steps.length - 1);
  const bindOk = (b) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$/.test(b.name.trim()) && /^\/(?!.*\.\.)[A-Za-z0-9._/-]{0,200}$/.test(b.path.trim());
  const bindsOk = $derived(binds.every(bindOk) && new Set(binds.map((b) => b.name.trim())).size === binds.length);
  const vmBulk = $derived(type === 'vm' && binds.some((b) => b.kind !== 'fast'));
  // a kind other than a VM has no install image: drop a choice made before the kind changed
  $effect(() => { if (type !== 'vm' && iso) iso = ''; });
  // the next step: not until the name is given; a step the kind does not have is skipped by `steps`
  const canNext = $derived(step > 0 || name.trim() !== '');

  const args = () => {
    if (!name.trim()) return null;
    const a = [name.trim(), 'create', '--type', type];
    if (ram.trim()) a.push('--ram', ram.trim());
    if (cpu.trim()) a.push('--cpu', cpu.trim());
    if (disk.trim()) a.push('--disk', disk.trim());
    if (address.trim()) a.push('--address', address.trim());
    if (profile) a.push('--profile', profile);
    if (pool) a.push('--pool', pool);
    if (type === 'vm' && iso) a.push('--iso', iso);
    if (!bindsOk || vmBulk) return null;
    for (const b of binds) a.push('--bind', `${b.kind}:${b.name.trim()}:${b.path.trim()}${b.ro ? ':ro' : ''}`);
    return a;
  };
</script>

<CreateDialog title="Create an instance" area="ct" {args} {ondone}>
  {#snippet form()}
    <ol class="steps" aria-label="Steps">
      {#each steps as s, i (s.id)}
        <li class:on={i === step} class:done={i < step}><button type="button" class="stepbtn" aria-current={i === step ? 'step' : undefined} disabled={i > 0 && !name.trim()} onclick={() => { step = i; }}><span class="n">{i + 1}</span>{s.label}</button></li>
      {/each}
    </ol>
    {#if cur === 'basics'}<StepBasics bind:name bind:type />
    {:else if cur === 'resources'}<StepResources bind:ram bind:cpu bind:disk {type} />
    {:else if cur === 'placement'}<StepPlacement bind:pool />
    {:else if cur === 'media'}<StepMedia bind:iso />
    {:else}<StepNetwork bind:address bind:profile bind:binds {type} />{/if}
    <div class="nav">
      <Button type="button" disabled={step === 0} onclick={() => { step = Math.max(0, step - 1); }}>Back</Button>
      {#if !last}<Button type="button" variant="primary" disabled={!canNext} onclick={() => { step += 1; }}>Next</Button>{/if}
    </div>
  {/snippet}
</CreateDialog>

<style>
  .steps { display: flex; flex-wrap: wrap; gap: 4px 14px; list-style: none; margin: 0; padding: 0; font-size: 12.5px; }
  .stepbtn { display: inline-flex; align-items: center; gap: 6px; padding: 2px 0; border: 0; background: none; color: var(--fg-3); font: inherit; cursor: pointer; }
  .stepbtn:disabled { cursor: default; opacity: 0.5; }
  .on .stepbtn { color: var(--fg); font-weight: 600; }
  .done .stepbtn { color: var(--fg-2); }
  .n { display: inline-grid; place-items: center; width: 18px; height: 18px; font-size: 11px; border: 1px solid var(--line-2); }
  .on .n { border-color: var(--accent); background: var(--accent); color: var(--accent-ink); }
  .nav { display: flex; justify-content: space-between; margin-top: 4px; }
</style>
