// Static design preview only. No dependencies, uploads, proxying or network features.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = __dirname;
const port = Number(process.env.VAULT_DESIGN_PORT || 4178);
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.mp4': 'video/mp4' };
http.createServer((request, response) => {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, { Allow: 'GET, HEAD' }).end();
    return;
  }
  let pathname;
  try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
  catch { response.writeHead(400).end('Invalid URL'); return; }
  if (pathname.includes('\0')) { response.writeHead(400).end('Invalid path'); return; }
  const file = path.resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
  if (!file.startsWith(root + path.sep)) { response.writeHead(403).end(); return; }
  fs.stat(file, (error, stat) => {
    if (error || !stat.isFile()) { response.writeHead(404).end('Not found'); return; }
    let start = 0;
    let end = stat.size - 1;
    let status = 200;
    if (request.headers.range) {
      const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.range);
      if (!range || (!range[1] && !range[2])) {
        response.writeHead(416, { 'Content-Range': `bytes */${stat.size}` }).end();
        return;
      }
      if (!range[1]) start = Math.max(0, stat.size - Number(range[2]));
      else {
        start = Number(range[1]);
        if (range[2]) end = Math.min(end, Number(range[2]));
      }
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= stat.size) {
        response.writeHead(416, { 'Content-Range': `bytes */${stat.size}` }).end();
        return;
      }
      status = 206;
    }
    const headers = {
      'Content-Type': types[path.extname(file)] || 'application/octet-stream',
      'Content-Length': Math.max(0, end - start + 1),
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Content-Security-Policy': "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; style-src 'self'; script-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
    };
    if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${stat.size}`;
    response.writeHead(status, headers);
    if (request.method === 'HEAD') { response.end(); return; }
    fs.createReadStream(file, {start, end}).on('error', () => response.destroy()).pipe(response);
  });
}).listen(port, '127.0.0.1', () => console.log(`Vault interface study: http://127.0.0.1:${port}`));
