<script>
  // Headless: reads the status document of ONE remote node (hs sys node status <name>, over ssh, the word status only) and reports a dot for the tree,
  // the capabilities the node names (its tree is built from them), the document itself (the dots of an edge node's rows) and, when it does not answer,
  // the reason. The answer can take a while or fail; no answer is a grey/red dot, never an error on the page. Nothing is drawn.
  import { poll } from '../data.svelte.js';
  let { name, onstate } = $props();
  // the likely reason, from the words ssh and hs node use; the raw message is shown after it
  const reason = (e) => {
    const m = String(e?.message ?? '');
    if (/key/i.test(m) && /(no key|missing|changed)/i.test(m)) return `The key is missing or was changed (${m}).`;
    if (/vault/i.test(m)) return 'The vault is closed on this server, so the key cannot be used (hs unlock).';
    if (/timed? ?out|timeout/i.test(m)) return 'The server did not answer in time: it is off or the network is down.';
    return m ? `${m.replace(/[.]$/, '')}.` : "";
  };
  const st = poll(() => `/api/sys/node/status/${encodeURIComponent(name)}`, 60000);
  $effect(() => {
    const d = st.data;
    if (d) {
      const n = Number(d.problems ?? 0) || 0;
      const age = d.time ? Date.now() / 1000 - d.time : 0;
      const dot = n > 0 ? { state: 'warn', title: `${n} problem${n === 1 ? '' : 's'}` } : age > 600 ? { state: 'warn', title: 'the status document is old' } : { state: 'ok', title: 'online' };
      // an error after a good answer: the node stopped answering, the last document stays
      if (st.error) onstate(name, { state: 'bad', title: 'does not answer' }, 'down', { caps: Array.isArray(d.capabilities) ? d.capabilities : null, doc: d, why: reason(st.error) });
      else onstate(name, dot, 'ok', { caps: Array.isArray(d.capabilities) ? d.capabilities : null, doc: d });
    } else if (st.error) onstate(name, { state: 'bad', title: 'does not answer' }, 'down', { why: reason(st.error) });
    else onstate(name, { state: 'off', title: 'reading' }, 'loading');
  });
</script>
