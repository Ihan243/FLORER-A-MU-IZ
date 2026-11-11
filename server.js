const http = require('http');
const fs = require('fs');
const path = require('path');

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain; charset=utf-8',
  '.ico': 'image/x-icon',
};

// Cache index.html in memory
const indexHtml = fs.readFileSync(path.join(__dirname, 'index.html'));
const privacyHtml = fs.readFileSync(path.join(__dirname, 'aviso-privacidad.html'));

function handler(req, res) {
  const cleanUrl = decodeURIComponent((req.url || '/').split('?')[0]);
  
  if (cleanUrl === '/' || cleanUrl === '/index.html') {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
    });
    return res.end(indexHtml);
  }

  const machineReadableFiles = {
    '/robots.txt': {
      contentType: 'text/plain; charset=utf-8',
      body: 'User-agent: *\nAllow: /\n',
    },
    '/llms.txt': {
      contentType: 'text/plain; charset=utf-8',
      body: "# Florería Muñiz\n\n> Florería en Ameca, Jalisco, México. Consulta ramos, arreglos y flores, y solicita una cotización por WhatsApp.\n\nFlorería Muñiz atiende pedidos para ocasiones especiales, con opciones de recolección en el local y entrega a domicilio. La disponibilidad y el precio final de cada producto se confirman con la florería.\n\n## Información del negocio\n\n- Ubicación: Avenida Patria Poniente #200-B, al lado del Pollo Bronco y frente a la Secundaria #1, Ameca, Jalisco, México.\n- Horario: lunes a sábado, 8:00 AM–8:00 PM; domingos, 9:00 AM–3:00 PM.\n- WhatsApp: +52 375 756 1827.\n- Precios: los precios mostrados en el catálogo pueden cambiar y deben confirmarse.\n\n## Enlaces\n\n- [Sitio web](https://florer-a-mu-iz.vercel.app/): portada y acceso al catálogo y cotizador.\n- [Aviso de Privacidad](https://florer-a-mu-iz.vercel.app/aviso-privacidad.html): información sobre el uso de datos personales.\n- [WhatsApp](https://wa.me/523757561827): contacto para cotizaciones.\n",
    },
    '/ai-catalog.json': {
      contentType: 'application/json; charset=utf-8',
      body: "{\n  \"specVersion\": \"1.0\",\n  \"host\": {\n    \"displayName\": \"Florería Muñiz\",\n    \"documentationUrl\": \"https://florer-a-mu-iz.vercel.app/\"\n  },\n  \"entries\": []\n}\n",
    },
  };
  const machineReadableFile = machineReadableFiles[cleanUrl];
  if (machineReadableFile) {
    res.writeHead(200, {
      'Content-Type': machineReadableFile.contentType,
      'Cache-Control': 'public, max-age=86400',
    });
    return res.end(machineReadableFile.body);
  }

  // Always serve the full privacy notice at its public URL.
  if (cleanUrl === '/aviso-privacidad.html') {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
    });
    return res.end(privacyHtml);
  }

  // Attempt to serve static file from disk
  const safePath = path.normalize(cleanUrl).replace(/^(\.\.[\/\\])+/, '');
  const filePath = path.join(__dirname, safePath);

  try {
    if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
      const ext = path.extname(filePath).toLowerCase();
      const contentType = MIME_TYPES[ext] || 'application/octet-stream';
      res.writeHead(200, {
        'Content-Type': contentType,
        'Cache-Control': 'public, max-age=86400',
      });
      return fs.createReadStream(filePath).pipe(res);
    }
  } catch (err) {}

  // Fallback to index.html for SPA/anchor routes
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
  });
  res.end(indexHtml);
}

// Standalone execution for localhost
if (require.main === module) {
  const PORT = process.env.PORT || 3000;
  http.createServer(handler).listen(PORT, '0.0.0.0', () => {
    console.log(`🌸 Florería Muñiz activo en http://localhost:${PORT}`);
  });
}

module.exports = handler;
