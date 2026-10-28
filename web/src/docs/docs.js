// The guides in the web interface: what the server sends (index.json, a page as Markdown, a search) and the link rules between guides.
import { get, getText } from '../api.js';

export const loadIndex = () => get('/api/docs/index');
export const loadPage = (lang, slug) => getText(`/api/docs/page/${encodeURIComponent(lang)}/${encodeURIComponent(slug)}`);
export const search = (q, lang) => get(`/api/docs/search?q=${encodeURIComponent(q)}${lang ? `&lang=${encodeURIComponent(lang)}` : ''}`);

export const docPath = (lang, slug) => `/docs/${lang}/${slug}`;

// "/docs", "/docs/en", "/docs/en/install" -> { lang, slug } (empty strings where the address does not say)
export function parsePath(path) {
  const p = path.split('/').filter(Boolean);
  if (p[0] !== 'docs') return { lang: '', slug: '' };
  return { lang: p[1] === 'de' || p[1] === 'en' ? p[1] : '', slug: p[2] ?? '' };
}

// Which guide does a link in a guide mean? `href` is what the Markdown says: "Torrents%20mit%20VPN.md#abschnitt", "befehle-liste.md",
// "../en/start.md". The name is looked up as the file name in docs/ (index.json `file`) or as the page's slug; the language is the one
// the link names (a folder de/ or en/), else the page it is on, else the other one. Anything that is not a guide gives null.
export function makeResolver(index, currentLang) {
  const byFile = {};
  const bySlug = {};
  for (const [lang, info] of Object.entries(index?.langs ?? {})) {
    byFile[lang] = new Map();
    bySlug[lang] = new Set();
    for (const g of info.groups) for (const p of g.pages) { byFile[lang].set(p.file, p.slug); bySlug[lang].add(p.slug); }
    if (info.start) bySlug[lang].add(info.start);
  }
  return (href) => {
    const [pathPart, hash = ''] = href.split('#');
    let path;
    try { path = decodeURIComponent(pathPart); } catch { return null; }
    const segs = path.split('/').filter((s) => s && s !== '.' && s !== '..');
    const file = segs[segs.length - 1];
    if (!file || !file.toLowerCase().endsWith('.md')) return null;
    const hint = segs.find((s) => s === 'de' || s === 'en');
    const order = [...new Set([hint, currentLang, 'de', 'en'].filter(Boolean))];
    for (const lang of order) {
      if (!byFile[lang]) continue;
      const slug = byFile[lang].get(file) ?? (bySlug[lang].has(file.slice(0, -3)) ? file.slice(0, -3) : null);
      if (slug) return { lang, slug, hash };
    }
    return null;
  };
}

// the first page of a language: its start page, else the first page of the first group
export function firstPage(index, lang) {
  const info = index?.langs?.[lang];
  if (!info) return '';
  return info.start || info.groups?.[0]?.pages?.[0]?.slug || '';
}
