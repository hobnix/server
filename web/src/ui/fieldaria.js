// Pure helpers for the form field components (no svelte, tested with node in tests/web-formfields.mjs).
//   fieldIds('f-1')                                  -> { help: 'f-1-help', err: 'f-1-err' }
//   describedBy('f-1', { help: true, error: false }) -> 'f-1-help'   (space separated, undefined if none)
//   ariaFor({ id, help, error, required })           -> { id, 'aria-describedby', 'aria-invalid', 'aria-required' } (unset ones are undefined)
export function fieldIds(id) {
  return { help: `${id}-help`, err: `${id}-err` };
}

export function describedBy(id, { help = false, error = false } = {}) {
  const ids = fieldIds(id);
  const list = [];
  if (help) list.push(ids.help);
  if (error) list.push(ids.err);
  return list.length ? list.join(' ') : undefined;
}

export function ariaFor({ id, help = false, error = false, required = false } = {}) {
  return {
    id,
    'aria-describedby': describedBy(id, { help, error }),
    'aria-invalid': error ? 'true' : undefined,
    'aria-required': required ? 'true' : undefined,
  };
}
