import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';

import { filesystemStore, s3Store, signV4 } from '../src/blobstore.js';
import { makeContacts, signup, startServer } from './helpers.js';

describe('SigV4 signer', () => {
  test('matches the AWS test suite (get-vanilla)', () => {
    const h = signV4({
      method: 'GET',
      url: 'https://example.amazonaws.com/',
      headers: { host: 'example.amazonaws.com' },
      region: 'us-east-1',
      service: 'service',
      accessKeyId: 'AKIDEXAMPLE',
      secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
      date: new Date('2015-08-30T12:36:00Z'),
      signPayloadHeader: false,
    });
    assert.match(h.Authorization, /Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31$/);
  });

  test('matches botocore for an S3 PUT of an object key', () => {
    const body = Buffer.from('ciphertext bytes');
    const h = signV4({
      method: 'PUT',
      url: 'https://minio.example.com/sh-bucket/attachments/0b5e2b9e-6f6a-4c7e-9a0e-1f2d3c4b5a69.bin',
      headers: {
        host: 'minio.example.com',
        'content-type': 'application/octet-stream',
        'content-length': String(body.length),
      },
      body,
      region: 'us-east-1',
      service: 's3',
      accessKeyId: 'minioadmin',
      secretAccessKey: 'secret-key-123',
      date: new Date('2026-11-17T10:00:00Z'),
    });
    // Reference value computed with botocore's S3SigV4Auth.
    assert.match(h.Authorization, /Signature=f2ef179d8e8d0ccc2b17f9130e10d9d6eeed254f96c8b97d623365fd0779a66f$/);
  });
});

/** A tiny S3: checks every request's SigV4 signature, keeps objects in memory. */
async function fakeS3({ accessKeyId, secretAccessKey, region }) {
  const objects = new Map();
  const seen = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      const auth = String(req.headers.authorization ?? '');
      const signed = /SignedHeaders=([^,]+)/.exec(auth)?.[1].split(';') ?? [];
      const date = req.headers['x-amz-date'];
      const iso = `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}T${date.slice(9, 11)}:${date.slice(11, 13)}:${date.slice(13, 15)}Z`;
      const headers = Object.fromEntries(signed.filter((n) => !n.startsWith('x-amz-')).map((n) => [n, req.headers[n]]));
      const expected = signV4({
        method: req.method,
        url: `http://${req.headers.host}${req.url}`,
        headers,
        body,
        region,
        service: 's3',
        accessKeyId,
        secretAccessKey,
        date: new Date(iso),
      }).Authorization;
      seen.push({ method: req.method, url: req.url, ok: auth === expected });
      if (auth !== expected) {
        res.writeHead(403).end('<Error><Code>SignatureDoesNotMatch</Code></Error>');
        return;
      }
      if (req.method === 'PUT') {
        objects.set(req.url, body);
        res.writeHead(200).end();
      } else if (req.method === 'GET') {
        const o = objects.get(req.url);
        if (!o) res.writeHead(404).end();
        else res.writeHead(200, { 'content-type': 'application/octet-stream' }).end(o);
      } else if (req.method === 'DELETE') {
        objects.delete(req.url);
        res.writeHead(204).end();
      } else {
        res.writeHead(405).end();
      }
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { server, objects, seen, endpoint: `http://127.0.0.1:${server.address().port}` };
}

async function exercise(srv, a, b) {
  const blob = randomBytes(20_000);
  const up = await fetch(`${srv.base}/api/attachments`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${a.token}`, 'Content-Type': 'application/octet-stream' },
    body: blob,
  });
  assert.equal(up.status, 201);
  const { id } = await up.json();
  const { rows } = await srv.pool.query('SELECT data, storage FROM attachments WHERE id = $1', [id]);
  assert.equal(rows[0].data, null, 'bytes are not in Postgres');
  const down = await fetch(`${srv.base}/api/attachments/${id}`, { headers: { Authorization: `Bearer ${b.token}` } });
  assert.equal(down.status, 200);
  assert.deepEqual(Buffer.from(await down.arrayBuffer()), blob);
  return { id, blob, storage: rows[0].storage };
}

describe('filesystem storage (a folder on your VPS)', () => {
  let srv;
  let dir;
  before(async () => {
    dir = mkdtempSync(path.join(tmpdir(), 'sh-blobs-'));
    srv = await startServer({ blobs: filesystemStore(dir) });
  });
  after(() => srv.close());

  test('upload, download, delete and expiry use files on disk', async () => {
    const a = await signup(srv.base, 'fs_a');
    const b = await signup(srv.base, 'fs_b');
    await makeContacts(srv.base, a, b);
    const { id, blob, storage } = await exercise(srv, a, b);
    assert.equal(storage, 'filesystem');
    const file = path.join(dir, id.slice(0, 2), `${id}.bin`);
    assert.deepEqual(readFileSync(file), blob);

    const del = await fetch(`${srv.base}/api/attachments/${id}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${a.token}` },
    });
    assert.equal(del.status, 204);
    assert.equal(existsSync(file), false);

    const second = await exercise(srv, a, b);
    const file2 = path.join(dir, second.id.slice(0, 2), `${second.id}.bin`);
    await srv.pool.query("UPDATE attachments SET expires_at = now() - interval '1 second' WHERE id = $1", [second.id]);
    await srv.app.sweep();
    assert.equal(existsSync(file2), false, 'expired files are swept');
  });
});

describe('S3-compatible storage (e.g. MinIO on your VPS)', () => {
  let srv;
  let s3;
  const creds = { accessKeyId: 'sh-test-key', secretAccessKey: 'sh-test-secret-0123456789', region: 'us-east-1' };
  before(async () => {
    s3 = await fakeS3(creds);
    srv = await startServer({
      blobs: s3Store({
        S3_ENDPOINT: s3.endpoint,
        S3_BUCKET: 'sh-bucket',
        S3_REGION: creds.region,
        S3_ACCESS_KEY_ID: creds.accessKeyId,
        S3_SECRET_ACCESS_KEY: creds.secretAccessKey,
      }),
    });
  });
  after(async () => {
    await srv.close();
    s3.server.close();
  });

  test('every request is correctly signed; objects round-trip and are deleted on expiry', async () => {
    const a = await signup(srv.base, 's3_a');
    const b = await signup(srv.base, 's3_b');
    await makeContacts(srv.base, a, b);
    const { id, blob, storage } = await exercise(srv, a, b);
    assert.equal(storage, 's3');
    const key = `/sh-bucket/attachments/${id}.bin`;
    assert.deepEqual(s3.objects.get(key), blob);
    assert.ok(s3.seen.length >= 2 && s3.seen.every((r) => r.ok), JSON.stringify(s3.seen));

    await srv.pool.query("UPDATE attachments SET expires_at = now() - interval '1 second' WHERE id = $1", [id]);
    await srv.app.sweep();
    assert.equal(s3.objects.has(key), false);
  });

  test('a wrong secret is refused by the store and the upload fails cleanly', async () => {
    const bad = s3Store({
      S3_ENDPOINT: s3.endpoint,
      S3_BUCKET: 'sh-bucket',
      S3_ACCESS_KEY_ID: creds.accessKeyId,
      S3_SECRET_ACCESS_KEY: 'wrong',
    });
    await assert.rejects(bad.put('0b5e2b9e-6f6a-4c7e-9a0e-1f2d3c4b5a69', Buffer.from('x')), /403/);
    assert.throws(() => s3Store({ S3_BUCKET: 'x' }), /S3_ENDPOINT/);
  });
});
