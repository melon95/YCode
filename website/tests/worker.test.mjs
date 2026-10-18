import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(new URL('../worker.js', import.meta.url), 'utf8');
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const env = { ASSETS: { fetch: async request => new Response(request.method === 'HEAD' ? null : '0123456789', {
  headers: { 'Content-Length': '10', 'Content-Type': 'video/mp4', ETag: '"current"', 'Last-Modified': 'Sat, 17 Oct 2026 12:00:00 GMT' },
}) } };
const fetchAsset = (headers = {}, method = 'GET') => worker.fetch(new Request('https://example.com/assets/film.mp4', { method, headers }), env);

test('video ranges preserve exact bytes, including open and suffix ranges', async () => {
  for (const [range, content, bounds] of [['bytes=2-5', '2345', '2-5'], ['bytes=7-', '789', '7-9'], ['bytes=-3', '789', '7-9']]) {
    const response = await fetchAsset({ Range: range });
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('Content-Range'), `bytes ${bounds}/10`);
    assert.equal(response.headers.get('Content-Length'), String(content.length));
    assert.equal(await response.text(), content);
  }
});

test('HEAD ignores Range and retains full asset length without a body', async () => {
  const response = await fetchAsset({ Range: 'bytes=2-5' }, 'HEAD');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Length'), '10');
  assert.equal(response.headers.get('Content-Range'), null);
  assert.equal(await response.text(), '');
});

test('If-Range only returns partial bytes for matching strong validators', async () => {
  for (const validator of ['"current"', 'Sat, 17 Oct 2026 12:00:00 GMT']) {
    assert.equal((await fetchAsset({ Range: 'bytes=5-', 'If-Range': validator })).status, 206);
  }
  for (const validator of ['"old"', 'W/"current"', 'Fri, 16 Oct 2026 12:00:00 GMT']) {
    const response = await fetchAsset({ Range: 'bytes=5-', 'If-Range': validator });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('Content-Range'), null);
    assert.equal(await response.text(), '0123456789');
  }
});

test('unsatisfiable ranges report the full asset size', async () => {
  const response = await fetchAsset({ Range: 'bytes=10-' });
  assert.equal(response.status, 416);
  assert.equal(response.headers.get('Content-Range'), 'bytes */10');
});
