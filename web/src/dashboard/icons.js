// Descriptor icon names (the `icon` of a service: brand names and mdi-* of the recipes) -> Phosphor names. No CDN, no brand logos (CSP img-src 'self').
// Reuses the choices of web/src/pages/Apps.svelte. An unknown name has no entry: the tile draws a monogram.
export const icons = {
  jellyfin: 'film-strip', immich: 'images', seerr: 'magnifying-glass', grafana: 'chart-line', 'uptime-kuma': 'heartbeat', zoraxy: 'arrows-split',
  authentik: 'key', radarr: 'film-slate', sonarr: 'film-slate', lidarr: 'film-slate', prowlarr: 'film-slate', bazarr: 'film-slate',
  qbittorrent: 'download-simple', sabnzbd: 'download', tdarr: 'swap', ntfy: 'bell', synapse: 'chat-circle', 'home-assistant': 'house-line',
  robot: 'robot', 'cloud-arrow-up': 'cloud-arrow-up', 'mdi-email-outline': 'envelope-simple', 'mdi-email-lock': 'envelope-open',
  'mdi-gamepad-variant': 'game-controller', 'mdi-book-open-page-variant': 'book-open', 'mdi-application': 'app-window',
  arcane: 'shipping-container', portainer: 'shipping-container', dockge: 'shipping-container', docker: 'shipping-container', 'mdi-docker': 'shipping-container',
  cube: 'cube',
};
