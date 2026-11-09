// The package builder (ADR 0020): the form model and the package.toml text it makes. Pure, no DOM, tested with node (tests/web-builder.mjs).
// The text is only a draft: the server checks it (`hs sys pkg plan check-draft`, the checks of `hs pkg validate`); this file adds no rule of its own.

export const blank = () => ({ kind: 'recipe', name: '', title: '', version: '0.1.0', requires: '>=1', audience: 'generic', script: 'run.sh', permissions: '' });

const q = (s) => JSON.stringify(String(s));      // a TOML basic string: JSON escapes are valid TOML escapes
export const permissionList = (text) => String(text || '').split(/[\n,]+/).map((x) => x.trim()).filter(Boolean);

// the package.toml text of the form (the order of `hs pkg new`)
export function manifestText(f) {
  const out = [`name = ${q(f.name.trim())}`, `version = ${q(f.version.trim())}`, `kind = ${q(f.kind)}`, `title = ${q(f.title.trim())}`,
    `requires_core = ${q(f.requires.trim())}`, `audience = ${q(f.audience)}`];
  if (f.kind === 'recipe') out.push(`script = ${q(f.script.trim())}`);
  const perms = permissionList(f.permissions);
  if (perms.length) out.push(`permissions = [${perms.map(q).join(', ')}]`);
  return out.join('\n') + '\n';
}

// `finding` lines of the plan -> [{ level, where, text }] (errors first); the plan's own lines are [level, where, text]
export function findingsOf(list) {
  const f = (list || []).map(([level, where, text]) => ({ level, where: where === '-' ? '' : where, text }));
  return [...f.filter((x) => x.level === 'error'), ...f.filter((x) => x.level !== 'error')];
}

// the form field a finding belongs to (name, version, kind, title, requires_core -> requires, script, permissions), '' for none
export const fieldOf = (where) => (where === 'requires_core' ? 'requires' : ['name', 'version', 'kind', 'title', 'audience', 'script', 'permissions'].includes(where) ? where : '');
