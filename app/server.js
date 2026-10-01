'use strict';

/**
 * Small HTTP service used to exercise the platform: it reports which pod and
 * which version answered, so replica scaling and rolling updates can be
 * observed from the outside. No dependency besides Node.js itself.
 */
const http = require('node:http');
const os = require('node:os');

const config = {
  port: Number(process.env.PORT ?? 8080),
  version: process.env.APP_VERSION ?? 'dev',
  // Injected from the ConfigMap.
  greeting: process.env.GREETING ?? 'Hello',
  environment: process.env.ENVIRONMENT ?? 'local',
  // Injected from the Secret. Only its presence is ever reported.
  apiToken: process.env.API_TOKEN ?? '',
  shutdownDelayMs: Number(process.env.SHUTDOWN_DELAY_MS ?? 5000),
};

const state = { ready: true, requests: 0, startedAt: Date.now() };

/** Burns CPU for `ms` milliseconds: gives the autoscaler something to react to. */
function burnCpu(ms) {
  const until = Date.now() + ms;
  let value = 0;
  while (Date.now() < until) value += Math.sqrt(Math.random());
  return value;
}

function metrics() {
  const uptime = (Date.now() - state.startedAt) / 1000;
  return [
    '# HELP app_requests_total Requests served by this pod.',
    '# TYPE app_requests_total counter',
    `app_requests_total ${state.requests}`,
    '# HELP app_uptime_seconds Seconds since the process started.',
    '# TYPE app_uptime_seconds gauge',
    `app_uptime_seconds ${uptime.toFixed(0)}`,
    '# HELP app_memory_rss_bytes Resident memory of the process.',
    '# TYPE app_memory_rss_bytes gauge',
    `app_memory_rss_bytes ${process.memoryUsage().rss}`,
    '',
  ].join('\n');
}

function route(url) {
  switch (url.pathname) {
    case '/':
      return {
        body: {
          message: `${config.greeting} from ${os.hostname()}`,
          version: config.version,
          environment: config.environment,
          pod: os.hostname(),
          secretConfigured: config.apiToken.length > 0,
        },
      };
    // Liveness: the process is able to answer. Restart it otherwise.
    case '/healthz':
      return { body: { status: 'ok' } };
    // Readiness: the pod wants traffic. False while shutting down, so the
    // Service stops routing to it before the process exits.
    case '/readyz':
      return state.ready
        ? { body: { status: 'ready' } }
        : { status: 503, body: { status: 'shutting down' } };
    case '/metrics':
      return { text: metrics() };
    case '/work': {
      const ms = Math.min(Number(url.searchParams.get('ms') ?? 100) || 0, 2000);
      burnCpu(ms);
      return { body: { burnedMs: ms, pod: os.hostname() } };
    }
    default:
      return { status: 404, body: { error: 'Not found' } };
  }
}

function createServer() {
  return http.createServer((request, response) => {
    const url = new URL(request.url, 'http://localhost');
    const { status = 200, body, text } = route(url);
    if (url.pathname === '/' || url.pathname === '/work') state.requests++;

    response.writeHead(status, {
      'Content-Type': text ? 'text/plain; version=0.0.4' : 'application/json',
    });
    response.end(text ?? JSON.stringify(body));
  });
}

if (require.main === module) {
  const server = createServer();
  server.listen(config.port, () =>
    console.log(`v${config.version} listening on :${config.port}`),
  );

  // Kubernetes sends SIGTERM, then waits terminationGracePeriodSeconds. Fail
  // readiness first, keep serving while endpoints are updated, then exit.
  process.on('SIGTERM', () => {
    console.log('SIGTERM received, draining');
    state.ready = false;
    setTimeout(() => server.close(() => process.exit(0)), config.shutdownDelayMs);
  });
}

module.exports = { createServer, state, config };
