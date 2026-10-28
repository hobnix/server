<script>
  // The guides: a navigation (language, search, groups with their pages), the page rendered from Markdown, an outline of the page and
  // previous / next. Everything comes from /api/docs/* (capability docs; PageFrame handles "switched off").
  // Layout: the page scrolls as a whole (the shell's main area); the navigation and the outline stick while it does. On a phone the groups
  // fold into one section above the article.
  import { onMount, tick } from 'svelte';
  import { route, go, url } from '../route.svelte.js';
  import { render } from '../docs/markdown.js';
  import { loadIndex, loadPage, search, docPath, parsePath, makeResolver, firstPage } from '../docs/docs.js';
  import Banner from '../ui/Banner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import Skeleton from '../ui/Skeleton.svelte';

  let index = $state(null);
  let indexError = $state(null);          // { text, retry } while the list of guides cannot be read
  let source = $state('');
  let pageError = $state(null);           // { status, text } while the page cannot be read
  let loading = $state(false);
  let q = $state('');
  let hits = $state(null);                // null = not searching, [] = nothing found
  let searching = $state(false);
  let searchTimer;
  let article = $state();
  let navOpen = $state(false);            // the groups on a phone
  let toggled = $state({});               // group name -> true/false, set by a click; otherwise the group of the current page is open
  let activeId = $state('');
  let tries = $state(0);                  // bumped by "Try again" so the page is read once more

  async function start() {
    indexError = null;
    try { index = await loadIndex(); } catch (e) {
      indexError = {
        text: e.status === 404 ? (e.message === 'not built' ? 'The guides are not built yet. On the server: hs docs build' : 'The documentation page is switched off (machine.toml: webDocs).') : e.message,
        retry: e.status !== 404 ? start : null,
      };
    }
  }
  onMount(start);

  // the address decides: /docs (the start page of the browser's language), /docs/de, /docs/de/<slug>
  const wanted = $derived(parsePath(route.path));
  const lang = $derived.by(() => {
    if (wanted.lang) return wanted.lang;
    const first = (navigator.language || 'en').slice(0, 2) === 'de' ? 'de' : 'en';
    return index?.langs?.[first] ? first : Object.keys(index?.langs ?? {})[0] ?? 'de';
  });
  const slug = $derived(wanted.slug || firstPage(index, lang));
  const info = $derived(index?.langs?.[lang]);
  const resolve = $derived(makeResolver(index, lang));
  const rendered = $derived(source ? render(source, { resolve }) : { html: '', headings: [] });
  const flat = $derived((info?.groups ?? []).flatMap((g) => g.pages.map((p) => ({ ...p, group: g.name }))));
  const at = $derived(flat.findIndex((p) => p.slug === slug));
  const current = $derived(at >= 0 ? flat[at] : null);
  const prev = $derived(at > 0 ? flat[at - 1] : null);
  const next = $derived(at >= 0 && at < flat.length - 1 ? flat[at + 1] : null);
  const title = $derived(current?.title ?? rendered.headings[0]?.text ?? '');
  const outline = $derived(rendered.headings.filter((h) => h.level === 2 || h.level === 3));
  const isOpen = (g) => toggled[g.name] ?? g.pages.some((p) => p.slug === slug);

  // load the page when the address changes
  $effect(() => {
    const l = lang, s = slug;
    tries;
    if (!index || !s) return;
    loading = true;
    pageError = null;
    loadPage(l, s)
      .then(async (md) => {
        if (l !== lang || s !== slug) return;
        source = md;
        loading = false;
        await tick();
        const h = decodeURIComponent(location.hash.slice(1));
        if (h && document.getElementById(h)) document.getElementById(h).scrollIntoView();
        else scroller()?.scrollTo({ top: 0 });
      })
      .catch((e) => { if (l === lang && s === slug) { source = ''; loading = false; pageError = { status: e.status, text: e.message }; } });
  });

  const scroller = () => article?.closest('main') ?? document.scrollingElement;

  // copy buttons on the code blocks (the markup comes from the renderer; the buttons are added after it is in the page)
  $effect(() => {
    rendered.html;
    tick().then(() => {
      for (const pre of article?.querySelectorAll('pre') ?? []) {
        if (pre.querySelector('.copy')) continue;
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'copy';
        b.setAttribute('aria-label', 'Copy the code');
        b.innerHTML = '<i class="ph ph-copy"></i><span>Copy</span>';
        pre.append(b);
      }
    });
  });

  // the heading that is at the top of the screen marks itself in the outline
  $effect(() => {
    rendered.html;
    const root = article?.closest('main');
    if (!root || typeof IntersectionObserver === 'undefined') return;
    let obs;
    tick().then(() => {
      const hs = [...(article?.querySelectorAll('h2[id], h3[id]') ?? [])];
      obs = new IntersectionObserver((es) => {
        const e = es.filter((x) => x.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
        if (e) activeId = e.target.id;
      }, { root, rootMargin: '0px 0px -75% 0px' });
      hs.forEach((h) => obs.observe(h));
    });
    return () => obs?.disconnect();
  });

  function open(l, s, hash = '') {
    hits = null;
    q = '';
    navOpen = false;
    const path = docPath(l, s);
    if (path !== route.path) go(path);
    history.replaceState(null, '', url(path) + (hash ? '#' + hash : ''));
    if (hash) tick().then(() => document.getElementById(hash)?.scrollIntoView());
  }

  // a plain click opens the guide in place; a click with a modifier key keeps the browser's own way (new tab)
  function pick(e, l, s, hash = '') {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button) return;
    e.preventDefault();
    open(l, s, hash);
  }

  async function copy(btn) {
    const text = btn.closest('pre')?.querySelector('code')?.textContent ?? '';
    try {
      if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(text);
      else {
        const t = document.createElement('textarea');
        t.value = text;
        t.style.cssText = 'position:fixed;opacity:0';
        document.body.append(t);
        t.select();
        document.execCommand('copy');
        t.remove();
      }
      btn.querySelector('span').textContent = 'Copied';
      btn.classList.add('done');
    } catch {
      btn.querySelector('span').textContent = 'Not copied';
    }
    setTimeout(() => { btn.querySelector('span').textContent = 'Copy'; btn.classList.remove('done'); }, 1600);
  }

  function onclick(e) {
    const btn = e.target.closest?.('button.copy');
    if (btn) { copy(btn); return; }
    const a = e.target.closest?.('a');
    if (!a) return;
    if (a.dataset.doc) {
      e.preventDefault();
      const [l, s] = a.dataset.doc.split('/');
      open(l, s, a.dataset.hash ?? '');
    } else if (a.dataset.anchor !== undefined) {
      e.preventDefault();
      const id = a.dataset.anchor;
      document.getElementById(id)?.scrollIntoView();
      history.replaceState(null, '', location.pathname + '#' + id);
    }
  }

  function toId(e, id) {
    e.preventDefault();
    document.getElementById(id)?.scrollIntoView();
    history.replaceState(null, '', location.pathname + '#' + id);
    activeId = id;
  }

  function typing() {
    clearTimeout(searchTimer);
    if (q.trim().length < 2) { hits = null; searching = false; return; }
    const mine = q;
    searching = true;
    searchTimer = setTimeout(async () => {
      try { const r = await search(mine.trim(), ''); if (mine === q) hits = r.hits; } catch { if (mine === q) hits = []; }
      if (mine === q) searching = false;
    }, 200);
  }

  const clear = () => { q = ''; hits = null; searching = false; };
</script>

<div class="docs">
  <aside class="idx" aria-label="Guides">
    {#if info}
      <div class="langs" role="group" aria-label="Language">
        {#each Object.entries(index.langs) as [l, v]}
          <button class="lang" class:on={l === lang} aria-pressed={l === lang} onclick={() => open(l, firstPage(index, l))}>{l.toUpperCase()}<span class="ln">{v.label}</span></button>
        {/each}
      </div>
    {/if}
    <div class="find">
      <i class="ph ph-magnifying-glass"></i>
      <input class="input" type="search" placeholder="Search the guides" bind:value={q} oninput={typing} onkeydown={(e) => e.key === 'Escape' && clear()}
        autocomplete="off" spellcheck="false" aria-label="Search the guides" />
    </div>
    {#if info}
      <button class="navtoggle" aria-expanded={navOpen} aria-controls="docs-groups" onclick={() => (navOpen = !navOpen)}>
        <i class="ph ph-list"></i><span class="nt">{current?.title ?? 'All guides'}</span><i class="ph ph-caret-{navOpen ? 'up' : 'down'}"></i>
      </button>
      <nav id="docs-groups" class="groups" class:open={navOpen} aria-label="Pages">
        {#each info.groups as g (g.name)}
          {@const on = isOpen(g)}
          <div class="grp">
            <button class="gname" aria-expanded={on} onclick={() => (toggled[g.name] = !on)}>
              <i class="ph ph-caret-right" class:turn={on}></i><span>{g.name}</span><span class="cnt">{g.pages.length}</span>
            </button>
            {#if on}
              <ul>
                {#each g.pages as p (p.slug)}
                  <li><a class="pg" class:on={p.slug === slug} href={url(docPath(lang, p.slug))} aria-current={p.slug === slug ? 'page' : undefined}
                      onclick={(e) => pick(e, lang, p.slug)}>{p.title}</a></li>
                {/each}
              </ul>
            {/if}
          </div>
        {/each}
      </nav>
    {:else if !indexError}
      <Skeleton lines={7} height={14} gap={12} />
    {/if}
  </aside>

  <div class="col">
    {#if indexError}
      <Banner tone={indexError.retry ? 'bad' : 'info'}>
        {indexError.text}
        {#snippet action()}{#if indexError.retry}<button class="btn sm" onclick={indexError.retry}><i class="ph ph-arrow-clockwise"></i>Try again</button>{/if}{/snippet}
      </Banner>
    {:else if !index}
      <div class="sheet"><Skeleton lines={9} height={14} gap={14} /></div>
    {:else if hits || searching}
      <section class="sheet" aria-live="polite">
        <div class="crumb">Search</div>
        <h1 class="rh">{#if hits}{hits.length === 0 ? 'Nothing found' : hits.length === 1 ? '1 result' : `${hits.length} results`}{:else}Searching…{/if} <span class="for">for "{q.trim()}"</span></h1>
        {#if hits?.length}
          <ul class="results">
            {#each hits as h}
              <li>
                <a class="hit" href={url(docPath(h.lang, h.slug)) + (h.anchor ? '#' + h.anchor : '')} onclick={(e) => pick(e, h.lang, h.slug, h.anchor)}>
                  <span class="ht">{h.title}{#if h.lang !== lang}<span class="tag tag-neutral">{h.lang.toUpperCase()}</span>{/if}</span>
                  {#if h.heading && h.heading !== h.title}<span class="hh"><i class="ph ph-hash"></i>{h.heading}</span>{/if}
                  {#if h.snippet && h.snippet !== h.heading}<span class="hs">{h.snippet}</span>{/if}
                </a>
              </li>
            {/each}
          </ul>
        {:else if hits}
          <EmptyState icon="magnifying-glass" title="No guide mentions that" text="Try a shorter word, or the name of a command.">
            {#snippet action()}<button class="btn" onclick={clear}>Back to the guide</button>{/snippet}
          </EmptyState>
        {:else}
          <Skeleton lines={4} height={44} />
        {/if}
      </section>
    {:else if pageError}
      <section class="sheet">
        {#if pageError.status === 404}
          <EmptyState icon="file-dashed" title="This guide does not exist" text="The link may be from an older version of the guides. Pick a page in the list.">
            {#snippet action()}<button class="btn" onclick={() => open(lang, firstPage(index, lang))}>Go to the start page</button>{/snippet}
          </EmptyState>
        {:else}
          <Banner tone="bad">
            This page could not be read: {pageError.text}
            {#snippet action()}<button class="btn sm" onclick={() => tries++}><i class="ph ph-arrow-clockwise"></i>Try again</button>{/snippet}
          </Banner>
        {/if}
      </section>
    {:else}
      <div class="read">
        <section class="sheet">
          <div class="crumb">{current?.group ?? 'Docs'}</div>
          {#if !source}
            <Skeleton lines={9} height={14} gap={14} />
          {:else}
            <!-- the renderer escapes everything that is not Markdown syntax (web/src/docs/markdown.js, tests/web-docs-markdown.mjs) -->
            <article bind:this={article} class="doc" class:loading {onclick} onkeydown={null} role="document" aria-label={title}>{@html rendered.html}</article>
          {/if}
          {#if source && (prev || next)}
            <nav class="pn" aria-label="Previous and next guide">
              {#if prev}<a class="pnl" href={url(docPath(lang, prev.slug))} onclick={(e) => pick(e, lang, prev.slug)}><span class="k"><i class="ph ph-arrow-left"></i>Previous</span><span class="v">{prev.title}</span></a>{:else}<span></span>{/if}
              {#if next}<a class="pnl r" href={url(docPath(lang, next.slug))} onclick={(e) => pick(e, lang, next.slug)}><span class="k">Next<i class="ph ph-arrow-right"></i></span><span class="v">{next.title}</span></a>{/if}
            </nav>
          {/if}
        </section>
        {#if outline.length > 1}
          <aside class="toc" aria-label="On this page">
            <div class="tk">On this page</div>
            <ul>
              {#each outline as h (h.id)}
                <li class:l3={h.level === 3}><a href={'#' + h.id} class:on={h.id === activeId} onclick={(e) => toId(e, h.id)}>{h.text}</a></li>
              {/each}
            </ul>
          </aside>
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .docs { display: grid; grid-template-columns: 264px minmax(0, 1fr); gap: 20px; align-items: start; min-width: 0; }
  .col { min-width: 0; }
  .read { display: grid; grid-template-columns: minmax(0, 1fr); gap: 20px; align-items: start; }
  @media (min-width: 1500px) { .read:has(.toc) { grid-template-columns: minmax(0, 1fr) 210px; } }

  /* navigation: sticks while the article scrolls */
  .idx { position: sticky; top: 0; max-height: calc(100dvh - 150px); overflow: auto; display: flex; flex-direction: column; gap: 10px; padding: 12px; border: 1px solid var(--line); border-radius: var(--r); background: var(--panel); min-width: 0; }
  .langs { display: flex; }
  .lang { flex: 1; display: flex; align-items: baseline; justify-content: center; gap: 8px; padding: 6px 8px; border: 1px solid var(--line-2); background: none; cursor: pointer; font: 500 11px var(--mono); letter-spacing: .08em; color: var(--fg-2); }
  .lang + .lang { border-left: 0; }
  .lang .ln { font: 12px var(--sans, inherit); letter-spacing: 0; color: var(--fg-3); }
  .lang:hover { background: var(--panel-2); }
  .lang.on { background: var(--panel-3); color: var(--fg); box-shadow: inset 0 -2px 0 var(--accent); }
  .lang:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
  .find { position: relative; }
  .find i { position: absolute; left: 10px; top: 50%; transform: translateY(-50%); color: var(--fg-3); pointer-events: none; }
  .find .input { padding-left: 32px; }
  .navtoggle { display: none; align-items: center; gap: 10px; width: 100%; min-height: 38px; padding: 0 12px; border: 1px solid var(--line-2); background: var(--panel-2); cursor: pointer; text-align: left; }
  .navtoggle .nt { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 500; }
  .navtoggle:focus-visible, .gname:focus-visible, .pg:focus-visible, .pnl:focus-visible, .hit:focus-visible, .toc a:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
  .groups { display: flex; flex-direction: column; gap: 2px; }
  .gname { display: flex; align-items: center; gap: 8px; width: 100%; padding: 7px 4px; border: 0; background: none; cursor: pointer; text-align: left; font: 500 11px var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--fg-3); }
  .gname:hover { color: var(--fg); }
  .gname > span:not(.cnt) { flex: 1; min-width: 0; }
  .gname .ph-caret-right { font-size: 11px; transition: transform .12s; }
  .gname .ph-caret-right.turn { transform: rotate(90deg); }
  .cnt { font-size: 10.5px; color: var(--fg-3); }
  ul { list-style: none; margin: 0; padding: 0; }
  .grp ul { margin: 0 0 8px; border-left: 1px solid var(--line); }
  .pg { display: block; position: relative; padding: 6px 10px 6px 12px; font-size: 13px; line-height: 1.35; color: var(--fg-2); text-decoration: none; overflow-wrap: anywhere; }
  .pg:hover { background: var(--panel-2); color: var(--fg); }
  .pg.on { color: var(--fg); font-weight: 500; background: var(--panel-2); }
  .pg.on::before { content: ''; position: absolute; left: -1px; top: 0; bottom: 0; width: 2px; background: var(--accent); }

  /* the article */
  .sheet { padding: 22px 28px 26px; border: 1px solid var(--line); border-radius: var(--r); background: var(--panel); min-width: 0; }
  .crumb { font: 12px var(--mono); color: var(--fg-3); margin-bottom: 8px; }
  .rh { margin: 0 0 14px; font-size: 24px; font-weight: 600; letter-spacing: -0.02em; overflow-wrap: anywhere; }
  .rh .for { color: var(--fg-3); font-weight: 400; }
  .results { display: flex; flex-direction: column; border-top: 1px solid var(--line); }
  .hit { display: flex; flex-direction: column; gap: 3px; padding: 11px 6px; border-bottom: 1px solid var(--line); text-decoration: none; color: inherit; }
  .hit:hover { background: var(--panel-2); }
  .ht { display: flex; gap: 8px; align-items: center; font-weight: 500; color: var(--fg); }
  .hh { font: 12px var(--mono); color: var(--accent-ink); }
  .hs { font-size: 12.5px; color: var(--fg-3); overflow-wrap: anywhere; }

  .doc { font-size: 14.5px; line-height: 1.65; color: var(--fg); overflow-wrap: break-word; max-width: 860px; }
  .doc.loading { opacity: .5; }
  .doc :global(h1) { font-size: 28px; font-weight: 600; letter-spacing: -0.03em; line-height: 1.2; margin: 0 0 16px; }
  .doc :global(h2) { font-size: 19px; font-weight: 600; letter-spacing: -0.01em; margin: 34px 0 12px; padding-bottom: 8px; border-bottom: 1px solid var(--line); }
  .doc :global(h3) { font-size: 15.5px; font-weight: 600; margin: 24px 0 8px; }
  .doc :global(h4), .doc :global(h5), .doc :global(h6) { font: 500 11px var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--fg-3); margin: 20px 0 6px; }
  .doc :global(h1), .doc :global(h2), .doc :global(h3), .doc :global(h4) { scroll-margin-top: 14px; }
  .doc :global(p) { margin: 0 0 12px; }
  .doc :global(a) { color: var(--accent-ink); text-decoration: underline; text-decoration-color: color-mix(in oklch, var(--accent-ink) 40%, transparent); text-underline-offset: 2px; }
  .doc :global(a:hover) { text-decoration-color: currentColor; }
  .doc :global(a:focus-visible) { outline: 2px solid var(--accent); outline-offset: 2px; }
  .doc :global(strong) { font-weight: 600; }
  .doc :global(ul), .doc :global(ol) { margin: 0 0 12px; padding-left: 22px; }
  .doc :global(li) { margin: 3px 0; }
  .doc :global(li > ul), .doc :global(li > ol) { margin: 4px 0; }
  .doc :global(li.taskitem) { list-style: none; margin-left: -20px; display: flex; gap: 8px; align-items: baseline; }
  .doc :global(.taskbody) { flex: 1 1 0; min-width: 0; }
  .doc :global(.task) { flex: none; width: 14px; height: 14px; border: 1px solid var(--line-2); background: var(--panel-2); align-self: flex-start; margin-top: 5px; }
  .doc :global(.task.done) { background: var(--accent); border-color: transparent; }
  .doc :global(code) { font: 12.5px var(--mono); padding: 1px 5px; background: var(--panel-2); border: 1px solid var(--line); border-radius: var(--r); overflow-wrap: break-word; }
  .doc :global(pre) { position: relative; margin: 0 0 16px; padding: 14px 16px; overflow: auto; background: var(--bg); border: 1px solid var(--line-2); border-radius: var(--r); }
  .doc :global(pre code) { display: block; padding: 0; border: 0; background: none; font-size: 12.5px; line-height: 1.55; overflow-wrap: normal; white-space: pre; }
  .doc :global(pre .copy) { position: absolute; top: 6px; right: 6px; display: inline-flex; align-items: center; gap: 5px; padding: 3px 8px; border: 1px solid var(--line-2); border-radius: var(--r); background: var(--panel-2); color: var(--fg-2); font: 11px var(--mono); cursor: pointer; opacity: 0; transition: opacity .12s; }
  .doc :global(pre:hover .copy), .doc :global(pre .copy:focus-visible), .doc :global(pre .copy.done) { opacity: 1; }
  .doc :global(pre .copy:hover) { color: var(--fg); border-color: var(--fg-3); }
  .doc :global(pre .copy:focus-visible) { outline: 2px solid var(--accent); outline-offset: 1px; }
  .doc :global(pre .copy.done) { color: var(--ok); }
  .doc :global(blockquote) { margin: 0 0 14px; padding: 10px 16px; background: color-mix(in oklch, var(--accent) 8%, var(--panel)); border: 1px solid var(--line); border-left: 3px solid var(--accent); color: var(--fg-2); }
  .doc :global(blockquote > :last-child) { margin-bottom: 0; }
  .doc :global(hr) { border: 0; height: 1px; background: var(--line); margin: 24px 0; }
  .doc :global(img) { max-width: 100%; height: auto; }
  /* a table wider than the article scrolls inside it, the page never scrolls sideways */
  .doc :global(.tablewrap) { max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; margin: 0 0 16px; border: 1px solid var(--line); }
  .doc :global(table) { border-collapse: collapse; font-size: 13px; min-width: 100%; }
  .doc :global(td) { min-width: 6ch; }
  .doc :global(th), .doc :global(td) { padding: 7px 12px; text-align: left; vertical-align: top; border-bottom: 1px solid var(--line); }
  .doc :global(tbody tr:last-child td) { border-bottom: 0; }
  .doc :global(th) { font: 500 11px var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--fg-3); background: var(--panel-2); white-space: nowrap; }
  .doc :global(td) { color: var(--fg-2); }

  .pn { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; max-width: 860px; margin-top: 34px; padding-top: 18px; border-top: 1px solid var(--line); }
  .pnl { display: flex; flex-direction: column; gap: 4px; min-width: 0; padding: 10px 14px; border: 1px solid var(--line-2); text-decoration: none; color: inherit; }
  .pnl.r { text-align: right; align-items: flex-end; grid-column: 2; }
  .pnl:hover { border-color: var(--accent); background: var(--panel-2); }
  .pnl .k { display: inline-flex; align-items: center; gap: 6px; font: 11px var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--fg-3); }
  .pnl .v { font-weight: 500; overflow-wrap: anywhere; }

  /* the outline of the page, wide screens only */
  .toc { position: sticky; top: 0; max-height: calc(100dvh - 150px); overflow: auto; font-size: 12.5px; }
  .tk { font: 500 11px var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--fg-3); margin-bottom: 8px; }
  .toc ul { border-left: 1px solid var(--line); }
  .toc a { display: block; position: relative; padding: 4px 10px; color: var(--fg-3); text-decoration: none; overflow-wrap: anywhere; line-height: 1.35; }
  .toc .l3 a { padding-left: 22px; }
  .toc a:hover { color: var(--fg); }
  .toc a.on { color: var(--fg); }
  .toc a.on::before { content: ''; position: absolute; left: -1px; top: 0; bottom: 0; width: 2px; background: var(--accent); }

  @media (max-width: 860px) {
    .docs { grid-template-columns: minmax(0, 1fr); gap: 14px; }
    .idx { position: static; max-height: none; overflow: visible; }
    .navtoggle { display: flex; }
    .groups { display: none; max-height: 55dvh; overflow: auto; }
    .groups.open { display: flex; }
    .sheet { padding: 16px 14px 20px; }
    .doc { font-size: 14px; }
    .doc :global(h1) { font-size: 23px; }
    .doc :global(pre .copy) { opacity: 1; }
    .pn { grid-template-columns: 1fr; }
    .pnl.r { grid-column: 1; }
  }
  @media (prefers-reduced-motion: reduce) { .gname .ph-caret-right { transition: none; } }
</style>
