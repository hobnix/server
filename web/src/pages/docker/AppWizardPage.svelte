<script>
  // The guided way to a new Docker app: image, ports, folders, variables, one question per screen (ui/Wizard.svelte, the frame the capability
  // wizards use). The last screen shows the compose file and the .env text it will hand over, as plain text, and "Open in editor" opens
  // /instances/docker/new on exactly that text. The wizard saves and applies nothing: the editor's Test, Save and Apply do (editor/wizard.js has the logic).
  import { poll, rows } from '../../data.svelte.js';
  import { go } from '../../route.svelte.js';
  import { tr } from '../../i18n.js';
  import PageHeader from '../../shell/PageHeader.svelte';
  import Wizard from '../../ui/Wizard.svelte';
  import Button from '../../ui/Button.svelte';
  import Banner from '../../ui/Banner.svelte';
  import Combobox from '../../ui/Combobox.svelte';
  import { mountsOf } from '../../editor/volumes.js';
  import { emptyDraft, suggestName, problems, generate, notes, RESTART, setHandoff } from '../../editor/wizard.js';

  const STEPS = ['image', 'ports', 'storage', 'env', 'review'];
  const sharesPoll = poll('/api/sys/shares/list', 30000);
  const storPoll = poll('/api/sys/ct/storage/docker', 15000);
  const remotePoll = poll('/api/sys/remote/list', 30000);
  const mounts = $derived(mountsOf(rows(storPoll)));
  const shareOptions = $derived([
    ...rows(sharesPoll).map((r) => r[0]).filter(Boolean).map((s) => ({ value: s, label: s })),
    ...rows(remotePoll).filter((r) => r[0] === 'mount' && r[4] === 'mounted').map((r) => ({ value: `remote:${r[1]}`, label: `${r[1]} (${tr('another server, read only')})` })),
  ]);

  let at = $state(0);
  let d = $state(emptyDraft());
  let nameTouched = $state(false);
  const step = $derived(STEPS[at]);
  const errs = $derived(step === 'review' ? [] : problems(step, d));
  const out = $derived(generate(d, mounts));
  const remarks = $derived(notes(d, mounts));

  const QUESTION = { image: 'Which image should run?', ports: 'Which ports should the app listen on?', storage: 'Which folders should the app keep?', env: 'Which settings does the app need?', review: 'Is this what you want?' };
  const HELP = {
    image: 'The image from a registry, with its tag, for example nginx:alpine. The name is the folder of the app in /opt/apps.',
    ports: 'The number on the left is the one on this server, the right one is inside the app. Skip this step for an app with no web page or port.',
    storage: 'A share keeps the files where the backups and the other apps see them. Without one the data lives in a folder next to the compose file.',
    env: 'Each setting is a NAME and a value, written to the .env text. Passwords stay there, never in the compose file.',
    review: 'This is the text the editor opens with. Nothing is saved or started yet: you can still change every line there.',
  };

  function onimage() { if (!nameTouched) d.name = suggestName(d.image); }
  function next() {
    if (errs.length) return;
    if (step === 'review') { setHandoff({ name: out.name, compose: out.compose, env: out.env }); go('/instances/docker/new'); return; }
    at += 1;
  }
  const addPort = () => d.ports.push({ host: '', container: '', proto: 'tcp' });
  const addVol = () => d.volumes.push({ kind: shareOptions.length ? 'share' : 'folder', share: '', sub: '', cpath: '', ro: false });
  const addEnv = () => d.env.push({ key: '', value: '' });
  const drop = (list, i) => list.splice(i, 1);
  const secret = (k) => /PASS|TOKEN|SECRET|KEY/i.test(k);
</script>

<PageHeader title="New app" crumb="Docker" sub="Answer a few questions; the editor opens with the compose file and the .env text." />

<div class="wrap">
  <Wizard index={at} total={STEPS.length} question={tr(QUESTION[step])} help={tr(HELP[step])} primary={step === 'review' ? tr('Open in editor') : tr('Next')} canNext={!errs.length} onnext={next} onback={() => { at = Math.max(0, at - 1); }}>
    {#if step === 'image'}
      <label class="f">{tr('Image')}
        <input class="input" bind:value={d.image} oninput={onimage} placeholder="nginx:alpine" autocapitalize="off" autocorrect="off" spellcheck="false" />
      </label>
      <label class="f">{tr('Name')}
        <input class="input" bind:value={d.name} oninput={() => { nameTouched = true; }} placeholder="my-app" autocapitalize="off" autocorrect="off" spellcheck="false" />
      </label>
      <label class="f">{tr('Restart')}
        <Combobox options={RESTART} bind:value={d.restart} />
      </label>
    {:else if step === 'ports'}
      {#each d.ports as p, i}
        <div class="row">
          <input class="input num" bind:value={p.host} placeholder="8080" inputmode="numeric" aria-label={tr('Port on this server')} />
          <span>→</span>
          <input class="input num" bind:value={p.container} placeholder="80" inputmode="numeric" aria-label={tr('Port inside the app')} />
          <Combobox options={['tcp', 'udp']} bind:value={p.proto} />
          <Button variant="ghost" icon="trash" aria-label={tr('Remove')} onclick={() => drop(d.ports, i)} />
        </div>
      {/each}
      <div><Button icon="plus" onclick={addPort}>{tr('Add a port')}</Button></div>
    {:else if step === 'storage'}
      {#each d.volumes as v, i}
        <div class="row wrapr">
          <Combobox options={[{ value: 'share', label: tr('A share') }, { value: 'folder', label: tr('A folder of the app') }]} bind:value={v.kind} />
          {#if v.kind === 'share'}<Combobox options={shareOptions} bind:value={v.share} placeholder={tr('Share')} />{/if}
          <input class="input" bind:value={v.sub} placeholder={tr('subfolder (optional)')} autocapitalize="off" spellcheck="false" aria-label={tr('Subfolder')} />
          <span>→</span>
          <input class="input" bind:value={v.cpath} placeholder="/data" autocapitalize="off" spellcheck="false" aria-label={tr('Path inside the app')} />
          <label class="chk"><input type="checkbox" bind:checked={v.ro} /> {tr('read only')}</label>
          <Button variant="ghost" icon="trash" aria-label={tr('Remove')} onclick={() => drop(d.volumes, i)} />
        </div>
      {/each}
      <div><Button icon="plus" onclick={addVol}>{tr('Add a folder')}</Button></div>
      {#each remarks.filter((r) => r.startsWith('The share')) as r}<Banner tone="info">{r}</Banner>{/each}
    {:else if step === 'env'}
      {#each d.env as e, i}
        <div class="row">
          <input class="input" bind:value={e.key} placeholder="TZ" autocapitalize="off" spellcheck="false" aria-label={tr('Name')} />
          <span>=</span>
          <input class="input" type={secret(e.key) ? 'password' : 'text'} bind:value={e.value} placeholder={tr('value')} autocomplete="off" spellcheck="false" aria-label={tr('Value')} />
          <Button variant="ghost" icon="trash" aria-label={tr('Remove')} onclick={() => drop(d.env, i)} />
        </div>
      {/each}
      <div><Button icon="plus" onclick={addEnv}>{tr('Add a setting')}</Button></div>
    {:else}
      <div class="rev">
        <div class="ph">docker-compose.yml</div><pre>{out.compose}</pre>
        <div class="ph">.env</div><pre>{out.env || tr('(empty)')}</pre>
      </div>
      {#each remarks as r}<Banner tone="info">{r}</Banner>{/each}
    {/if}
    {#each errs as e}<Banner tone="bad">{tr(e)}</Banner>{/each}
  </Wizard>
</div>

<style>
  .wrap { max-width: 640px; margin-top: 12px; }
  .f { display: flex; flex-direction: column; gap: 4px; }
  .row { display: flex; align-items: center; gap: 8px; }
  .wrapr { flex-wrap: wrap; }
  .num { max-width: 100px; }
  .chk { display: flex; align-items: center; gap: 4px; font-size: 12px; color: var(--fg-2); }
  .rev { border: 1px solid var(--line); background: var(--panel); }
  .ph { padding: 6px 12px; font: 12px var(--mono); color: var(--fg-2); border-bottom: 1px solid var(--line); }
  pre { margin: 0; padding: 8px 12px; font: 12px var(--mono); overflow-x: auto; white-space: pre; }
</style>
