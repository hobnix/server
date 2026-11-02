// The glue of the compose editor: the only file that imports CodeMirror and `yaml`. It is loaded with `await import('../../editor/cm.js')`
// when the editor page opens, so the main bundle does not grow. All decisions are in the plain modules next to it (lint.js, schema.js,
// envmask.js, envlang.js, yamlpath.js), which node tests run.
//   createEditor(el, { doc, lang: 'yaml' | 'env', onChange(text), lint(text, obj) -> findings, schema, envNames() -> [names], readOnly })
//   options.mounts() -> the docker mounts [{ path, ... }] and options.listDir(mount, rel) -> Promise<[folder names]> complete a volumes entry
//     -> { getText, setText, setReadOnly, relint, setFindings(list), focus, insertVolume(entry), destroy }
// Colours come from CSS variables only (--panel --fg --fg-3 --line --accent --ok --warn --bad), so the dark/light toggle needs no reconfigure.
import { EditorState, Compartment, StateEffect, StateField, RangeSetBuilder } from '@codemirror/state';
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, Decoration, WidgetType } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { StreamLanguage, syntaxHighlighting, HighlightStyle, indentUnit } from '@codemirror/language';
import { autocompletion, completionKeymap } from '@codemirror/autocomplete';
import { linter, lintGutter, lintKeymap, forceLinting } from '@codemirror/lint';
import { searchKeymap, highlightSelectionMatches } from '@codemirror/search';
import { yaml as yamlLang } from '@codemirror/lang-yaml';
import { tags as t } from '@lezer/highlight';
import { parseDocument, isMap } from 'yaml';
import { maskRanges } from './envmask.js';
import { envTokenizer } from './envlang.js';
import { candidates } from './schema.js';
import { locate } from './yamlpath.js';
import { varPrefixAt, volumeEntryAt, volumeCandidates, insertVolumeEdit } from './volumes.js';

const SEMANTIC_MAX = 64 * 1024;      // over this size only the syntax is checked
const LINT_DELAY = 500;
const LS_DELAY = 300;      // the folder listing of a share is asked 300 ms after the last key

const theme = EditorView.theme({
  '&': { height: '100%', color: 'var(--fg)', backgroundColor: 'var(--panel)', fontFamily: 'var(--mono)', fontSize: '13px' },
  '&.cm-focused': { outline: '1px solid var(--accent)' },
  '.cm-scroller': { fontFamily: 'var(--mono)', overflow: 'auto' },
  '.cm-content': { caretColor: 'var(--accent)' },
  '.cm-cursor': { borderLeftColor: 'var(--accent)' },
  '.cm-gutters': { backgroundColor: 'var(--panel)', color: 'var(--fg-3)', border: 'none', borderRight: '1px solid var(--line)' },
  '.cm-activeLine': { backgroundColor: 'transparent', outline: '1px solid var(--line)' },
  '.cm-activeLineGutter': { backgroundColor: 'transparent', color: 'var(--fg)' },
  '.cm-selectionBackground, &.cm-focused .cm-selectionBackground, ::selection': { backgroundColor: 'var(--accent)', opacity: '0.35' },
  '.cm-tooltip': { backgroundColor: 'var(--panel)', color: 'var(--fg)', border: '1px solid var(--line)' },
  '.cm-tooltip-autocomplete ul li[aria-selected]': { backgroundColor: 'var(--accent)', color: 'var(--accent-ink)' },
  '.cm-completionDetail': { color: 'var(--fg-3)' },
  '.cm-diagnostic-error': { borderLeft: '3px solid var(--bad)' },
  '.cm-diagnostic-warning': { borderLeft: '3px solid var(--warn)' },
  '.cm-lintRange-error': { backgroundImage: 'none', textDecoration: 'underline wavy var(--bad)' },
  '.cm-lintRange-warning': { backgroundImage: 'none', textDecoration: 'underline wavy var(--warn)' },
  '.cm-mask': { color: 'var(--fg-3)', letterSpacing: '1px' },
  '.cm-eye': { all: 'unset', cursor: 'pointer', color: 'var(--fg-3)', padding: '0 4px', fontFamily: 'var(--mono)' },
  '.cm-eye:hover': { color: 'var(--accent)' },
}, { dark: false });

const highlight = HighlightStyle.define([
  { tag: t.comment, color: 'var(--fg-3)' },
  { tag: [t.propertyName, t.variableName, t.definition(t.propertyName)], color: 'var(--accent)' },
  { tag: [t.string, t.content], color: 'var(--fg)' },
  { tag: [t.number, t.bool, t.null, t.keyword], color: 'var(--ok)' },
  { tag: [t.operator, t.punctuation, t.separator], color: 'var(--fg-3)' },
  { tag: t.invalid, color: 'var(--bad)' },
]);

// ── masked values of secret-looking keys, one eye button per line ──
const toggleReveal = StateEffect.define();

class EyeWidget extends WidgetType {
  constructor(name, shown) { super(); this.name = name; this.shown = shown; }
  eq(o) { return o.name === this.name && o.shown === this.shown; }
  ignoreEvent() { return true; }
  toDOM(view) {
    const wrap = document.createElement('span');
    if (!this.shown) {
      const dots = document.createElement('span');
      dots.className = 'cm-mask';
      dots.textContent = '••••••••';
      wrap.appendChild(dots);
    }
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'cm-eye';
    b.textContent = this.shown ? 'hide' : 'show';
    b.setAttribute('aria-label', `${this.shown ? 'Hide' : 'Show'} the value of ${this.name}`);
    b.title = this.shown ? 'Hide the value' : 'Show the value';
    b.addEventListener('mousedown', (e) => { e.preventDefault(); view.dispatch({ effects: toggleReveal.of(this.name) }); });
    wrap.appendChild(b);
    return wrap;
  }
}

function buildMasks(state, revealed) {
  const b = new RangeSetBuilder();
  for (const r of maskRanges(state.doc.toString())) {
    if (revealed.has(r.name)) b.add(r.to, r.to, Decoration.widget({ widget: new EyeWidget(r.name, true), side: 1 }));
    else b.add(r.from, r.to, Decoration.replace({ widget: new EyeWidget(r.name, false) }));
  }
  return b.finish();
}

const maskField = StateField.define({
  create: (state) => ({ revealed: new Set(), deco: buildMasks(state, new Set()) }),
  update(v, tr) {
    let revealed = v.revealed;
    for (const e of tr.effects) {
      if (e.is(toggleReveal)) {
        revealed = new Set(revealed);
        if (revealed.has(e.value)) revealed.delete(e.value); else revealed.add(e.value);
      }
    }
    if (tr.docChanged || revealed !== v.revealed) return { revealed, deco: buildMasks(tr.state, revealed) };
    return v;
  },
  provide: (f) => [
    EditorView.decorations.from(f, (v) => v.deco),
    EditorView.atomicRanges.of((view) => view.state.field(f).deco),
  ],
});

// ── lint: the yaml parser for the syntax, the page's function for the rest ──
function rangeOfPath(doc, path, textLength) {
  if (!path.length) return [0, Math.min(textLength, 1)];
  const parent = doc.getIn(path.slice(0, -1), true);
  const last = path[path.length - 1];
  if (isMap(parent)) {
    const pair = parent.items.find((p) => String(p.key && p.key.value !== undefined ? p.key.value : p.key) === String(last));
    if (pair && pair.key && pair.key.range) return [pair.key.range[0], pair.key.range[1]];
  }
  const node = doc.getIn(path, true);
  if (node && node.range) return [node.range[0], Math.max(node.range[1], node.range[0] + 1)];
  return null;
}

function lintSource(options, serverFindings) {
  return (view) => {
    const text = view.state.doc.toString();
    const out = [];
    const clamp = (n) => Math.max(0, Math.min(n, text.length));
    let obj = null;
    let doc = null;
    if (options.lang === 'yaml') {
      doc = parseDocument(text);
      for (const e of doc.errors) out.push({ from: clamp(e.pos[0]), to: clamp(Math.max(e.pos[1], e.pos[0] + 1)), severity: 'error', message: e.message.split('\n')[0] });
      for (const w of doc.warnings) out.push({ from: clamp(w.pos[0]), to: clamp(Math.max(w.pos[1], w.pos[0] + 1)), severity: 'warning', message: w.message.split('\n')[0] });
      if (!doc.errors.length) obj = doc.toJS();
    }
    const place = (f) => {
      let range = null;
      if (f.line && f.line >= 1 && f.line <= view.state.doc.lines) { const l = view.state.doc.line(f.line); range = [l.from, Math.max(l.to, l.from + 1)]; }
      else if (f.path) {
        if (!doc && options.lang === 'yaml') doc = parseDocument(text);
        if (doc) range = rangeOfPath(doc, f.path, text.length);
      }
      if (!range) range = [0, Math.min(text.length, 1)];
      out.push({ from: clamp(range[0]), to: clamp(range[1]), severity: f.level === 'error' ? 'error' : 'warning', message: f.text });
    };
    if (options.lint && text.length <= SEMANTIC_MAX && (options.lang === 'env' || obj !== null)) {
      for (const f of options.lint(text, obj) || []) place(f);
    }
    for (const f of serverFindings()) place(f);      // what the Test found on the server (cleared when the text changes)
    return out;
  };
}

// ── completion ──
function completionSource(options) {
  return async (ctx) => {
    const text = ctx.state.doc.toString();
    const before = text.slice(0, ctx.pos);
    // ${NAME} first: it works in any value, also inside a volumes entry (- ${DATA}/x:/data)
    const vp = varPrefixAt(before);
    const ve = vp === null && options.lang === 'yaml' && options.mounts ? volumeEntryAt(text, ctx.pos) : null;
    if (ve) {
      const c = volumeCandidates(ve.prefix, options.mounts());
      if (c.kind === 'roots') return { from: ctx.pos - ve.prefix.length, options: c.items.map((x) => ({ label: x, type: 'folder' })), validFor: /^[^:\s]*$/ };
      if (c.kind === 'dir' && options.listDir) {
        await new Promise((r) => setTimeout(r, LS_DELAY));
        if (ctx.aborted) return null;
        let names = [];
        try { names = await options.listDir(c.mount, c.rel); } catch { /* the share cannot be listed: no suggestions */ }
        if (ctx.aborted) return null;
        return { from: ctx.pos - c.typed.length, options: names.map((n) => ({ label: n + '/', type: 'folder' })), validFor: /^[^:\s/]*$/ };
      }
      return null;
    }
    if (vp !== null && options.envNames) {
      return { from: ctx.pos - vp.length, options: options.envNames().map((n) => ({ label: n, type: 'variable', apply: n + '}' })), validFor: /^[A-Za-z0-9_]*$/ };
    }
    if (options.lang !== 'yaml' || !options.schema) return null;
    const loc = locate(text, ctx.pos);
    if (!loc || (!ctx.explicit && !loc.prefix && loc.mode === 'key')) return null;
    const c = candidates(options.schema, loc.path);
    const list = loc.mode === 'key'
      ? c.keys.map((k) => ({ label: k.name, type: 'property', detail: k.detail ? k.detail.slice(0, 60) : '', apply: k.name + ': ' }))
      : c.values.map((x) => ({ label: x, type: 'enum' }));
    if (!list.length) return null;
    return { from: ctx.pos - loc.prefix.length, options: list, validFor: /^[\w.-]*$/ };
  };
}

export function createEditor(el, options = {}) {
  const lang = options.lang === 'env' ? 'env' : 'yaml';
  const opts = { ...options, lang };
  const readOnly = new Compartment();
  let server = [];      // the findings of the last Test for this text
  const ro = (on) => [EditorState.readOnly.of(!!on), EditorView.editable.of(!on)];
  const extensions = [
    lineNumbers(), highlightActiveLineGutter(), highlightActiveLine(), drawSelection(), history(), highlightSelectionMatches(),
    indentUnit.of('  '),
    keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap, ...completionKeymap, ...lintKeymap, indentWithTab]),
    lang === 'env' ? StreamLanguage.define(envTokenizer) : yamlLang(),
    syntaxHighlighting(highlight),
    theme,
    EditorView.contentAttributes.of({ autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false' }),
    autocompletion({ override: [completionSource(opts)], activateOnTyping: true }),
    linter(lintSource(opts, () => server), { delay: LINT_DELAY }),
    lintGutter(),
    readOnly.of(ro(opts.readOnly)),
    EditorView.updateListener.of((u) => { if (u.docChanged) { server = []; if (opts.onChange) opts.onChange(u.state.doc.toString()); } }),
  ];
  if (lang === 'env') extensions.push(maskField);
  const view = new EditorView({ parent: el, state: EditorState.create({ doc: opts.doc || '', extensions }) });
  return {
    getText: () => view.state.doc.toString(),
    setText: (text) => view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } }),
    setReadOnly: (on) => view.dispatch({ effects: readOnly.reconfigure(ro(on)) }),
    relint: () => forceLinting(view),
    // show the findings of the Test now: [{ level, text, line | path }]; they go when the text is changed
    setFindings: (list) => { server = Array.isArray(list) ? list : []; forceLinting(view); },
    focus: () => view.focus(),
    // add `- <entry>` under the volumes: of the service the cursor is in; without a readable services: block at the cursor line
    insertVolume: (entry) => {
      const text = view.state.doc.toString();
      let e = insertVolumeEdit(text, view.state.selection.main.head, entry);
      if (!e) { const at = view.state.selection.main.head; const ins = `- ${entry}\n`; e = { from: at, insert: ins, cursor: at + ins.length }; }
      view.dispatch({ changes: { from: e.from, insert: e.insert }, selection: { anchor: e.cursor }, scrollIntoView: true });
      view.focus();
    },
    destroy: () => view.destroy(),
  };
}
