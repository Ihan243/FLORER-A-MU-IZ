const http = require('http');
const fs = require('fs');
const path = require('path');

// Statically read essential files so Vercel bundler packages them
const indexHtml = fs.readFileSync(path.join(__dirname, 'index.html'));

let codeHtml = indexHtml;
try {
  codeHtml = fs.readFileSync(path.join(__dirname, 'code.html'));
} catch (e) {
  codeHtml = indexHtml;
}

let screenPng = null;
try {
  screenPng = fs.readFileSync(path.join(__dirname, 'screen.png'));
} catch (e) {}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  if (url === '/screen.png' && screenPng) {
    res.writeHead(200, {
      'Content-Type': 'image/png',
      'Cache-Control': 'public, max-age=86400',
    });
    return res.end(screenPng);
  }

  if (url === '/code' || url === '/code.html') {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'public, max-age=3600',
    });
    return res.end(codeHtml);
  }

  // Serve index.html for all other routes
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'public, max-age=3600',
  });
  res.end(indexHtml);
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, '0.0.0.0', () => {
  console.log(`🌸 Servidor Florería Muñiz activo en puerto ${PORT}`);
});

module.exports = server;
