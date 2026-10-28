import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// `npm run dev` talks to a backend on the same machine:  HS_WEB_ROOT=/nonexistent python3 scripts/web-serve.py 8480
const backend = process.env.HS_WEB_DEV_BACKEND || 'http://127.0.0.1:8480';

export default defineConfig({
  plugins: [svelte()],
  server: {
    proxy: {
      '/api': { target: backend, changeOrigin: false },
      '/theme.css': { target: backend, changeOrigin: false },
    },
  },
});
