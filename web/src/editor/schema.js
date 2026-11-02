// Walks the vendored compose-spec JSON schema at run time (no generated file). Pure: the schema is passed in.
//   candidates(schema, path)  -> { keys: [{ name, detail }], values: [string] } for a YAML path such as ['services', 'web', 'restart']
//   unknownKeys(schema, obj)  -> [path] of keys the schema does not know (a warning, never an error: the schema may lag Docker)
// A path segment is a key (string) or an array index (number). Handles $ref, patternProperties, oneOf/anyOf/allOf and $defs.

function deref(schema, node) {
  let n = node;
  for (let i = 0; i < 20 && n && typeof n === 'object' && typeof n.$ref === 'string'; i++) {
    const ref = n.$ref;
    if (!ref.startsWith('#/')) return {};
    let t = schema;
    for (const p of ref.slice(2).split('/')) t = t == null ? t : t[decodeURIComponent(p)];
    n = t;
  }
  return n && typeof n === 'object' ? n : {};
}

// a node and everything it can also be (oneOf, anyOf, allOf), $refs resolved
function expand(schema, node, seen = new Set()) {
  const n = deref(schema, node);
  if (seen.has(n)) return [];
  seen.add(n);
  const out = [n];
  for (const k of ['oneOf', 'anyOf', 'allOf']) {
    if (Array.isArray(n[k])) for (const s of n[k]) out.push(...expand(schema, s, seen));
  }
  return out;
}

// the nodes that describe the child `seg` of any of `nodes`; [] when none does
function step(schema, nodes, seg) {
  const out = [];
  for (const n of nodes) {
    if (typeof seg === 'number') {
      if (n.items && typeof n.items === 'object') out.push(...expand(schema, n.items));
      continue;
    }
    if (n.properties && Object.prototype.hasOwnProperty.call(n.properties, seg)) { out.push(...expand(schema, n.properties[seg])); continue; }
    let hit = false;
    if (n.patternProperties) {
      for (const [re, sub] of Object.entries(n.patternProperties)) {
        let rx;
        try { rx = new RegExp(re); } catch { continue; }
        if (rx.test(seg)) { out.push(...expand(schema, sub)); hit = true; }
      }
    }
    if (!hit && n.additionalProperties && typeof n.additionalProperties === 'object') out.push(...expand(schema, n.additionalProperties));
  }
  return out;
}

function walk(schema, path) {
  let nodes = expand(schema, schema);
  for (const seg of path) {
    nodes = step(schema, nodes, seg);
    if (!nodes.length) return [];
  }
  return nodes;
}

import { VALUE_HINTS } from './volumes.js';

export function candidates(schema, path) {
  const keys = new Map();
  const values = new Set();
  for (const n of walk(schema, path)) {
    if (n.properties) {
      for (const [name, sub] of Object.entries(n.properties)) {
        if (!keys.has(name)) keys.set(name, deref(schema, sub).description || '');
      }
    }
    if (Array.isArray(n.enum)) for (const v of n.enum) if (typeof v === 'string') values.add(v);
    if (typeof n.const === 'string') values.add(n.const);
    if (n.type === 'boolean') { values.add('true'); values.add('false'); }
  }
  // the spec leaves a few values open (restart, network_mode, pull_policy): offer the usual ones
  const last = path[path.length - 1];
  if (!values.size && path[0] === 'services' && path.length === 3 && Object.hasOwn(VALUE_HINTS, last)) for (const v of VALUE_HINTS[last]) values.add(v);
  return { keys: [...keys].map(([name, detail]) => ({ name, detail })), values: [...values] };
}

export function unknownKeys(schema, obj) {
  const out = [];
  const visit = (nodes, value, path) => {
    if (Array.isArray(value)) {
      value.forEach((v, i) => { const next = step(schema, nodes, i); if (next.length) visit(next, v, [...path, i]); });
      return;
    }
    if (!value || typeof value !== 'object') return;
    const strict = nodes.length > 0 && nodes.some((n) => n.properties) && nodes.every((n) => !n.additionalProperties || n.additionalProperties === false || !n.properties);
    for (const key of Object.keys(value)) {
      const next = step(schema, nodes, key);
      if (!next.length) {
        if (strict && !key.startsWith('x-')) out.push([...path, key]);
        continue;
      }
      visit(next, value[key], [...path, key]);
    }
  };
  visit(expand(schema, schema), obj, []);
  return out;
}
