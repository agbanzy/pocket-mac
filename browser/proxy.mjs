// Zero-dependency static file server for the built browser client (`dist/`). Used to preview or to
// self-host the bundle without Vite. In production the DO droplet's Caddy serves `dist/` directly;
// this exists so `npm run serve` works anywhere Node does. Usage: `PORT=5174 node proxy.mjs`.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(fileURLToPath(new URL('.', import.meta.url)), 'dist');
const PORT = Number(process.env.PORT ?? 5174);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
  '.map': 'application/json',
};

const server = createServer(async (req, res) => {
  try {
    // Strip query, prevent path traversal, default to index.html.
    const urlPath = decodeURIComponent((req.url ?? '/').split('?')[0]);
    let rel = normalize(urlPath).replace(/^(\.\.[/\\])+/, '');
    if (rel === '/' || rel.endsWith('/')) rel = join(rel, 'index.html');

    let filePath = join(ROOT, rel);
    let body;
    try {
      body = await readFile(filePath);
    } catch {
      // SPA fallback: unknown non-asset paths serve index.html.
      filePath = join(ROOT, 'index.html');
      body = await readFile(filePath);
    }
    res.writeHead(200, { 'content-type': MIME[extname(filePath)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(500);
    res.end('server error');
  }
});

server.listen(PORT, () => console.log(`Pocket Mac browser client on http://localhost:${PORT}`));
