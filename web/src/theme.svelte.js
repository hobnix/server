// Light / dark: follows the system until the toggle in the top bar is used; the choice is kept in this browser only (localStorage may be
// blocked, then it simply does not persist). The tokens react to <html data-theme="dark|light"> (tokens.css); no attribute = follow the system.
const KEY = 'hs-theme';
export const theme = $state({ pref: 'system', dark: true });   // pref: 'system' | 'dark' | 'light'; dark = what is on screen now

const mq = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;

function apply() {
  const el = document.documentElement;
  if (theme.pref === 'system') el.removeAttribute('data-theme');
  else el.setAttribute('data-theme', theme.pref);
  theme.dark = theme.pref === 'system' ? (mq ? mq.matches : true) : theme.pref === 'dark';
}

export function initTheme() {
  try { const v = localStorage.getItem(KEY); if (v === 'dark' || v === 'light') theme.pref = v; } catch { /* no memory */ }
  mq?.addEventListener?.('change', apply);
  apply();
}

// toggle between the two looks (the first click leaves "system" for the opposite of what is shown)
export function toggleTheme() {
  theme.pref = theme.dark ? 'light' : 'dark';
  try { localStorage.setItem(KEY, theme.pref); } catch { /* no memory */ }
  apply();
}
