<script>
  // The Hobnix mark (branding: .github/branding/logo-*.svg). The ring follows the text colour of the theme (light on dark, dark on light)
  // and the lambda stroke is the accent, so a changed accent (webAccent, /theme.css) recolours it; nothing here is hard-coded.
  //   <Logo size={26} />
  let { size = 26 } = $props();
</script>

<svg class="logo" viewBox="0 0 100 100" width={size} height={size} role="img" aria-label="hobnix">
  <circle cx="50" cy="50" r="38" fill="none" stroke-width="6" />
  <path d="M36.5 33.5 L63.5 66.5 M50 50 L36.5 66.5" fill="none" stroke-width="7" />
</svg>

<style>
  .logo { display: block; flex: none; }
  .logo circle { stroke: var(--fg); }
  .logo path { stroke: var(--accent); }
</style>
