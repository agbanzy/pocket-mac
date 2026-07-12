import { defineConfig } from 'vite';

// Static SPA build. `base: './'` keeps asset URLs relative so the bundle can be
// served from any path — the DO droplet's Caddy mounts it under /app, and it also
// works from file://-style previews and GitHub Pages without reconfiguration.
export default defineConfig({
  base: './',
  build: {
    target: 'es2022',
    outDir: 'dist',
    sourcemap: false,
  },
  server: {
    port: 5174,
    host: true,
  },
});
