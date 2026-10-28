// The interface language of the pages that are translated in the browser (today: the sign-in page; the guides have their own switch). Kept in this
// browser only; the first visit follows the browser language (de -> German, anything else English). t(table) picks the text of the current language.
const KEY = 'hs-lang';
const guess = () => {
  try { const v = localStorage.getItem(KEY); if (v === 'de' || v === 'en') return v; } catch { /* no memory */ }
  return (navigator.language || 'en').toLowerCase().startsWith('de') ? 'de' : 'en';
};

export const lang = $state({ code: guess() });

export function setLang(code) {
  lang.code = code === 'de' ? 'de' : 'en';
  try { localStorage.setItem(KEY, lang.code); } catch { /* no memory */ }
  document.documentElement.lang = lang.code;
}

// t({ en: 'Sign in', de: 'Anmelden' })
export const t = (o) => o[lang.code] ?? o.en;

// The server's runtime setting `language` (session answer, features.language): used until somebody chose a language in this browser.
export function initLang(code) {
  if (code !== 'de' && code !== 'en') return;
  try { if (localStorage.getItem(KEY)) return; } catch { /* no memory */ }
  lang.code = code;
  document.documentElement.lang = code;
}
