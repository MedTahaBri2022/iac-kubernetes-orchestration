'use strict';

const assert = require('node:assert/strict');
const { after, before, test } = require('node:test');
const { createServer, state } = require('./server');

let server;
let base;

before(async () => {
  server = createServer();
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test('reports the pod, the version and never the secret itself', async () => {
  const body = await (await fetch(`${base}/`)).json();

  assert.equal(body.version, 'dev');
  assert.equal(typeof body.pod, 'string');
  assert.equal(body.secretConfigured, false);
  assert.ok(!JSON.stringify(body).includes('API_TOKEN'));
});

test('liveness and readiness answer 200 while running', async () => {
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  assert.equal((await fetch(`${base}/readyz`)).status, 200);
});

test('readiness fails while draining, liveness does not', async () => {
  state.ready = false;
  try {
    assert.equal((await fetch(`${base}/readyz`)).status, 503);
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
  } finally {
    state.ready = true;
  }
});

test('exposes request metrics by route and status', async () => {
  await fetch(`${base}/`);
  await fetch(`${base}/fail`);
  const text = await (await fetch(`${base}/metrics`)).text();

  assert.match(text, /^http_requests_total\{route="\/",status="200"\} \d+$/m);
  assert.match(text, /^http_requests_total\{route="\/fail",status="500"\} 1$/m);
  assert.match(text, /^http_request_duration_seconds_bucket\{le="\+Inf"\} \d+$/m);
  assert.match(text, /^app_info\{version="dev"\} 1$/m);
  assert.match(text, /^app_memory_rss_bytes \d+$/m);
});

test('unknown paths share one label value', async () => {
  await fetch(`${base}/random-${Date.now()}`);
  await fetch(`${base}/another-${Date.now()}`);
  const text = await (await fetch(`${base}/metrics`)).text();

  assert.match(text, /^http_requests_total\{route="other",status="404"\} \d+$/m);
  assert.doesNotMatch(text, /route="\/random/);
});

test('the simulated failure answers 500', async () => {
  assert.equal((await fetch(`${base}/fail`)).status, 500);
});

test('caps the CPU burn so one request cannot hang a pod', async () => {
  const startedAt = Date.now();
  const body = await (await fetch(`${base}/work?ms=999999`)).json();

  assert.equal(body.burnedMs, 2000);
  assert.ok(Date.now() - startedAt < 4000);
});

test('unknown paths return 404', async () => {
  assert.equal((await fetch(`${base}/nope`)).status, 404);
});
