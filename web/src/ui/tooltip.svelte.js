// A tooltip in the design language (hard edges, panel colours, the same popover look as the Combobox). ONE tooltip element for the whole app
// (ui/Tooltip.svelte, mounted in App.svelte); a control asks for it with an action:
//   <button use:tip={'Back up now'}>                      <button use:tip={{ text: 'Update', keys: 'U', side: 'bottom' }}>
// text '' / undefined = no tooltip (a conditional one: use:tip={disabled ? reason : ''}). side: top (default), bottom, left, right; flipped when there
// is no room. Shows after 450 ms of hovering (at once while another one was closed less than 400 ms ago) and at once on KEYBOARD focus; hides on leaving,
// blur, a press, Esc, scrolling and resizing. Touch never shows it (no sticky tips). The trigger gets aria-describedby while it is open.
// A disabled button gets no pointer events in most browsers, so while it is disabled the action watches its parent and hit-tests the pointer.
export const TIP_ID = 'hs-tooltip';
export const tipState = $state({ open: false, text: '', keys: '', rect: { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }, pref: 'top' });

const DELAY = 450, GRACE = 400;
let owner = null, timer = 0, closedAt = 0, global = false;

function norm(p) {
  if (!p) return { text: '' };
  if (typeof p === 'string') return { text: p };
  return { text: p.text || '', keys: p.keys || '', side: p.side || 'top' };
}

function show(node, p) {
  clearTimeout(timer);
  timer = 0;
  if (!p.text) return;
  if (owner && owner !== node) owner.removeAttribute('aria-describedby');
  owner = node;
  const r = node.getBoundingClientRect();
  tipState.rect = { top: r.top, bottom: r.bottom, left: r.left, right: r.right, width: r.width, height: r.height };
  tipState.text = p.text;
  tipState.keys = p.keys || '';
  tipState.pref = p.side || 'top';
  tipState.open = true;
  node.setAttribute('aria-describedby', TIP_ID);
}

function hide(node) {
  clearTimeout(timer);
  timer = 0;
  if (node && owner !== node) return;
  if (owner) owner.removeAttribute('aria-describedby');
  if (tipState.open) closedAt = Date.now();
  tipState.open = false;
  owner = null;
}

function ensureGlobal() {
  if (global || typeof window === 'undefined') return;
  global = true;
  window.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(owner); }, true);
  window.addEventListener('scroll', () => hide(owner), true);
  window.addEventListener('resize', () => hide(owner));
}

export function tip(node, param) {
  let p = norm(param);
  ensureGlobal();
  const hover = () => {
    if (!p.text) return;
    clearTimeout(timer);
    if (Date.now() - closedAt < GRACE || tipState.open) show(node, p);
    else timer = setTimeout(() => show(node, p), DELAY);
  };
  const enter = (e) => { if (e.pointerType !== 'touch') hover(); };
  const leave = () => hide(node);
  const focus = () => { if (p.text && node.matches(':focus-visible')) show(node, p); };
  // the parent sees the pointer over a disabled control
  const inside = (e) => { const r = node.getBoundingClientRect(); return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom; };
  const pmove = (e) => {
    if (!node.disabled || e.pointerType === 'touch') return;
    if (inside(e)) { if (owner !== node && !timer) hover(); } else if (owner === node || timer) hide(node);
  };
  const pleave = () => { if (node.disabled) hide(node); };
  node.addEventListener('pointerenter', enter);
  node.addEventListener('pointerleave', leave);
  node.addEventListener('pointerdown', leave);
  node.addEventListener('focus', focus);
  node.addEventListener('blur', leave);
  const parent = node.parentElement;
  parent?.addEventListener('pointermove', pmove);
  parent?.addEventListener('pointerleave', pleave);
  return {
    update(v) {
      p = norm(v);
      if (owner === node) { if (p.text) show(node, p); else hide(node); }
    },
    destroy() {
      hide(node);
      node.removeEventListener('pointerenter', enter);
      node.removeEventListener('pointerleave', leave);
      node.removeEventListener('pointerdown', leave);
      node.removeEventListener('focus', focus);
      node.removeEventListener('blur', leave);
      parent?.removeEventListener('pointermove', pmove);
      parent?.removeEventListener('pointerleave', pleave);
    },
  };
}
