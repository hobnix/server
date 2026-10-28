<script>
  // Add disks (design: "Create dialog" > "Add disks", three variants):
  //   fast / ZFS bulk : exactly 2 free disks become a new mirror vdev (red, the pool name is typed to confirm)
  //   bulk SnapRAID   : "Add empty disks" (role, filesystem, optional LUKS) or "Adopt disks" (one disk that already holds files)
  // The server's plan (hs sys pool plan <pool> add|adopt ...) decides what is allowed and what must be typed; this form only collects the choices.
  import CreateDialog from '../../shell/CreateDialog.svelte';
  import DiskPicker from './DiskPicker.svelte';
  import { poll, rows } from '../../data.svelte.js';
  import { parseInfo } from '../../pages/storage/pool.js';
  import { freeDisks, FS } from './disks.js';

  let { pool: pool0 = 'bulk', variant: variant0 = 'empty', snap: snap0 = undefined } = $props();

  let pool = $state(pool0);
  let variant = $state(variant0);        // 'empty' | 'adopt' (only SnapRAID bulk)
  let picked = $state([]);
  let role = $state('data');
  let fs = $state('ext4');
  let encrypt = $state(false);
  let pass = $state('');
  let merge = $state(false);
  let chown = $state(false);

  const info = poll(() => `/api/sys/pool/info?pool=${pool}`, 60000);
  // the adopt listing also names encrypted disks (hs sys pool disks --role adopt), the plain one does not
  const free = poll(() => (variant === 'adopt' ? '/api/sys/pool/disks?role=adopt' : '/api/sys/pool/disks'), 15000);

  // does this pool use SnapRAID? the page that opened the form knows (snap0); a pool picked here is read
  const layout = $derived(parseInfo(rows(info)).facts.layout ?? '');
  const snap = $derived(pool === 'bulk' && (/SnapRAID/i.test(layout) || (!info.loaded && snap0 === true)));
  const disks = $derived(freeDisks(rows(free)));
  const adopting = $derived(snap && variant === 'adopt');
  const list = $derived(adopting ? disks.filter((d) => d.hasFiles || d.notes.some((n) => /encrypted/.test(n))) : disks);

  function setPool(p) { pool = p; picked = []; if (p !== 'bulk') variant = 'empty'; }
  function setVariant(v) { variant = v; picked = []; }

  const args = () => {
    if (!picked.length || !info.loaded) return null;
    if (adopting) return [pool, 'adopt', '--disks', picked[0], ...(merge ? ['--merge'] : []), ...(chown ? ['--chown'] : [])];
    if (!snap) return picked.length === 2 ? [pool, 'add', '--disks', picked.join(',')] : null;
    if (encrypt && !pass) return null;
    return [pool, 'add', '--disks', picked.join(','), '--role', role, '--fs', fs, ...(encrypt ? ['--encrypt'] : [])];
  };
  const stdin = () => (snap && !adopting && encrypt && pass ? pass : undefined);
  const title = $derived(adopting ? 'Adopt disks' : snap ? 'Add disks' : 'Add mirror pair');
</script>

<CreateDialog {title} kicker="Pool" area="pool" {args} {stdin}>
  {#snippet form()}
    <div class="field">
      <label for="ad-pool">Pool</label>
      <div class="seg" id="ad-pool" role="radiogroup" aria-label="Pool">
        {#each ['bulk', 'fast'] as p}
          <label class="seg-opt"><input type="radio" name="ad-pool" checked={pool === p} onchange={() => setPool(p)} />{p}</label>
        {/each}
      </div>
    </div>

    {#if snap}
      <div class="field">
        <label for="ad-var">What to add</label>
        <div class="seg" id="ad-var" role="radiogroup" aria-label="What to add">
          <label class="seg-opt"><input type="radio" name="ad-var" checked={variant === 'empty'} onchange={() => setVariant('empty')} />Add empty disks</label>
          <label class="seg-opt"><input type="radio" name="ad-var" checked={variant === 'adopt'} onchange={() => setVariant('adopt')} />Adopt disks</label>
        </div>
      </div>
    {/if}

    <div class="field">
      <label for="ad-disks">
        {#if adopting}A disk with files on it (it stays as it is, its files are brought into the pool){:else if snap}Free disks (they are erased){:else}Two free disks for the new mirror (they are erased){/if}
      </label>
      <div id="ad-disks">
        <DiskPicker disks={list} loaded={free.loaded} bind:picked single={adopting} empty={adopting ? 'No disk with files on it.' : 'No free disks.'} />
      </div>
      {#if !snap && !adopting}<div class="hint">{picked.length} of 2 picked{picked.length > 2 ? ': pick exactly two' : ''}</div>{/if}
    </div>

    {#if adopting}
      <label class="check"><input type="checkbox" bind:checked={merge} />Merge its folders into the existing shares</label>
      <label class="check"><input type="checkbox" bind:checked={chown} />Give the files to the file owner of the shares (chown)</label>
    {:else if snap}
      <div class="two">
        <div class="field">
          <label for="ad-role">Role</label>
          <select id="ad-role" class="input" bind:value={role}>
            <option value="data">data</option>
            <option value="parity">parity</option>
          </select>
        </div>
        <div class="field">
          <label for="ad-fs">Filesystem</label>
          <select id="ad-fs" class="input" bind:value={fs}>
            {#each FS as [v, t]}<option value={v}>{t}</option>{/each}
          </select>
        </div>
      </div>
      <label class="check"><input type="checkbox" bind:checked={encrypt} />Encrypt with LUKS</label>
      {#if encrypt}
        <div class="field">
          <label for="ad-pass">Passphrase (the one for all encrypted disks of this server; the first time it sets it)</label>
          <input id="ad-pass" class="input" type="password" bind:value={pass} autocomplete="new-password" spellcheck="false" />
          <div class="hint">It is sent to the server on its own and never appears in the command.</div>
        </div>
      {/if}
    {/if}
  {/snippet}
</CreateDialog>

<style>
  .two { display: grid; grid-template-columns: 1fr 1.6fr; gap: 12px; }
  .check { display: flex; align-items: center; gap: 8px; font-size: 13.5px; cursor: pointer; }
  .check input { accent-color: var(--color-accent); }
  .hint { font-size: 11.5px; color: var(--color-neutral-500); margin-top: 5px; }
  select.input { cursor: pointer; }
</style>
