const http = require('http');

const PORT = process.env.PORT || 3000;
const VERSION = process.env.VERSION || 'v1';
const ENVIRONMENT = process.env.ENVIRONMENT || 'production';
const MESSAGE = process.env.MESSAGE || 'hello';
const HEALTHY = process.env.HEALTHY !== 'false';
const COMMIT = process.env.GIT_COMMIT || 'unknown';

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    if (HEALTHY) {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('ok');
    } else {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('unhealthy');
    }
    return;
  }

  if (req.url === '/info') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      version: VERSION,
      environment: ENVIRONMENT,
      message: MESSAGE,
      healthy: HEALTHY,
      commit: COMMIT,
    }));
    return;
  }

  if (req.url === '/crash') {
    process.exit(1);
  }

  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(`<html><body><h1>${MESSAGE}</h1><p>version=${VERSION} env=${ENVIRONMENT}</p></body></html>`);
});

server.listen(PORT, () => {
  console.log(`listening on ${PORT}, version=${VERSION}`);
});
