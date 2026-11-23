import assert from 'node:assert/strict';
import { onRequestGet, source, target } from '../functions/download/[asset].js';

assert.equal(target('Rays.dmg').url, 'https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg');
assert.equal(target('Rays-0.1.16.zip').url, 'https://github.com/a6n-ai/rays/releases/download/v0.1.16/Rays-0.1.16.zip');
assert.equal(target('Rays-0.1.16.zip').version, '0.1.16');
for (const bad of ['Rays.exe', '../x', 'Rays-1.dmg', 'evil.com', 'Rays.dmg?x', '']) assert.equal(target(bad), null, bad);

assert.equal(source('brew', ''), 'brew');
assert.equal(source(null, 'Homebrew/4.6.0 (Macintosh)'), 'brew');
assert.equal(source('anything', 'curl/8'), 'direct');

const points = [];
const env = { DOWNLOADS: { writeDataPoint: (p) => points.push(p) } };
const req = (path) => new Request(`https://rays.a6n.ai${path}`);
let res = await onRequestGet({ request: req('/download/Rays.dmg?src=site'), params: { asset: 'Rays.dmg' }, env });
assert.equal(res.status, 302);
assert.equal(res.headers.get('location'), 'https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg');
assert.deepEqual(points[0].blobs.slice(0, 4), ['Rays.dmg', 'site', 'latest', 'dmg']);
res = await onRequestGet({ request: req('/download/x.dmg'), params: { asset: 'x.dmg' }, env });
assert.equal(res.status, 404);
assert.equal(points.length, 1);
res = await onRequestGet({ request: req('/download/Rays.dmg'), params: { asset: 'Rays.dmg' }, env: {} });
assert.equal(res.status, 302);
console.log('download.test.mjs: ok');
