// Optional integration check, using only Node's built-in crypto and HTTPS APIs.
import assert from 'node:assert/strict';
import { randomBytes, webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import https from 'node:https';

const target = new URL(process.env.PRIVATEBIN_TEST_URL || 'https://direct.example:14443');
const ca = process.env.PRIVATEBIN_TEST_CA ? readFileSync(process.env.PRIVATEBIN_TEST_CA) : undefined;
const request = (method, path, body) => new Promise((resolve, reject) => {
  const req = https.request({
    hostname: target.hostname, port: target.port || 443, path, method, ca,
    lookup: process.env.PRIVATEBIN_TEST_URL ? undefined : (_host, options, callback) => {
      if (options.all) callback(null, [{ address: '127.0.0.1', family: 4 }]);
      else callback(null, '127.0.0.1', 4);
    },
    headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'JSONHttpRequest' },
  }, res => {
    const chunks = [];
    res.on('data', chunk => chunks.push(chunk));
    res.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString())); }
      catch (error) { reject(error); }
    });
  });
  req.setTimeout(10000, () => req.destroy(new Error('PrivateBin request timed out')));
  req.on('error', reject);
  req.end(body && JSON.stringify(body));
});

const iv = randomBytes(16);
const salt = randomBytes(8);
const material = await webcrypto.subtle.importKey('raw', randomBytes(32), 'PBKDF2', false, ['deriveKey']);
const key = await webcrypto.subtle.deriveKey({ name: 'PBKDF2', salt, iterations: 100000, hash: 'SHA-256' },
  material, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
const adata = [[iv.toString('base64'), salt.toString('base64'), 100000, 256, 128, 'aes', 'gcm', 'none'], 'plaintext', 0, 0];
const algorithm = { name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(JSON.stringify(adata)), tagLength: 128 };
const ct = Buffer.from(await webcrypto.subtle.encrypt(algorithm, key,
  new TextEncoder().encode(JSON.stringify({ paste: 'PrivateBin integration check' })))).toString('base64');
const created = await request('POST', '/', { v: 2, adata, ct, meta: { expire: '5min' } });
assert.equal(created.status, 0, created.message);
assert.match(created.id, /^[a-f0-9]{16}$/);
const stored = await request('GET', `/?${created.id}`);
assert.equal(stored.status, 0, stored.message);
const decoded = await webcrypto.subtle.decrypt(algorithm, key, Buffer.from(stored.ct, 'base64'));
assert.equal(JSON.parse(new TextDecoder().decode(decoded)).paste, 'PrivateBin integration check');
console.log('PrivateBin encrypted paste create/read passed through RAW TLS fallback');
