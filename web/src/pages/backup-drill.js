// The drill rows of the Backup page. `hs sys backup state` gives drill_ok / drill_ct_ok as the epoch of the last
// PASSED drill and last_drill as the epoch of the last try; the old strings 'ok' and 'failed' are still understood.
const num = (v) => v !== undefined && v !== '' && v !== '-' && !isNaN(v);

// [text, dot state] of the file restore drill
export function restoreDrill(s, age) {
  const ok = s.drill_ok, last = s.last_drill;
  if (ok === 'ok') return [num(last) ? `passed · ${age(last)}` : 'passed', 'ok'];
  if (ok === 'failed') return [num(last) ? `failed · ${age(last)}` : 'failed', 'bad'];
  if (num(last) && (!num(ok) || Number(last) > Number(ok))) return [`failed · ${age(last)}`, 'bad'];
  if (num(ok)) return [`passed · ${age(ok)}`, 'ok'];
  return ['never', 'off'];
}

// [text, dot state] of the container drill, null without a container name
export function instanceDrill(s, age) {
  const name = s.drill_ct_name;
  if (!name || name === '-') return null;
  const ok = s.drill_ct_ok;
  if (ok === 'ok') return [`${name} · passed`, 'ok'];
  if (ok === 'failed') return [`${name} · failed`, 'bad'];
  if (num(ok)) return [`${name} · passed · ${age(ok)}`, 'ok'];
  return [`${name} · never passed`, 'off'];
}
