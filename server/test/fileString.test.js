// FTS1 codec: JavaScript port vs the Python reference (tools/file_to_string.py),
// driven through the reference's own CLI, in both directions.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import { describe, test } from 'node:test';

import * as fts from '../src/fileString.js';

const PY = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'tools', 'file_to_string.py');
const py = (...args) => execFileSync('python3', [PY, ...args], { encoding: 'utf8' });
const tmp = () => mkdtempSync(path.join(tmpdir(), 'fts-'));

const SAMPLES = {
  'empty.bin': Buffer.alloc(0),
  'one.bin': Buffer.from([0xff]),
  'odd.bin': Buffer.from([1, 2, 3]),
  'random.bin': randomBytes(100_003), // incompressible: stored as-is
  'text.txt': Buffer.from('Securely Hello — the quick brown fox 🦊\n'.repeat(5000)), // compresses
  'zeros.bin': Buffer.alloc(70_000),
};

describe('FTS1 codec (JavaScript) vs Python reference', () => {
  test('uncompressed output is byte-identical to Python, including non-ASCII names', () => {
    const dir = tmp();
    for (const name of ['plain.txt', 'résumé 😀.txt']) {
      const file = path.join(dir, name);
      writeFileSync(file, 'hello world, odd length!');
      for (const encoding of fts.ENCODINGS) {
        const ours = fts.encode(readFileSync(file), { filename: name, encoding, compress: false });
        const theirs = py('encode', file, '--encoding', encoding, '--no-compress').trim();
        assert.equal(ours, theirs, `${name} ${encoding}`);
      }
    }
  });

  test('Python encodes, JavaScript decodes (every sample, both encodings, compressed or not)', () => {
    const dir = tmp();
    for (const [name, bytes] of Object.entries(SAMPLES)) {
      const file = path.join(dir, name);
      writeFileSync(file, bytes);
      for (const encoding of fts.ENCODINGS) {
        for (const flag of [[], ['--no-compress']]) {
          const s = py('encode', file, '--encoding', encoding, ...flag).trim();
          const out = fts.decode(s);
          assert.equal(out.filename, name);
          assert.deepEqual(out.bytes, bytes, `${name} ${encoding} ${flag}`);
        }
      }
    }
  });

  test('JavaScript encodes, Python decodes', () => {
    for (const [name, bytes] of Object.entries(SAMPLES)) {
      for (const encoding of fts.ENCODINGS) {
        const dir = tmp();
        const enc = path.join(dir, 'encoded.txt');
        writeFileSync(enc, fts.encode(bytes, { filename: name, encoding }));
        const outDir = path.join(dir, 'out');
        py('decode', enc, '-o', outDir);
        assert.deepEqual(readFileSync(path.join(outDir, name)), bytes, `${name} ${encoding}`);
      }
    }
  });

  test('compression only when it helps', () => {
    const meta = (s) => JSON.parse(Buffer.from(s.split('|')[1], 'base64url').toString());
    assert.equal(meta(fts.encode(SAMPLES['text.txt'], { filename: 't' })).compressed, true);
    assert.equal(meta(fts.encode(SAMPLES['random.bin'], { filename: 'r' })).compressed, false);
  });

  test('chunks interoperate both ways and reassemble in any order', () => {
    const s = fts.encode(SAMPLES['random.bin'], { filename: 'random.bin', encoding: 'base45' });
    // JS chunks -> Python unchunk
    const dir = tmp();
    const chunkDir = path.join(dir, 'chunks');
    mkdirSync(chunkDir);
    const ours = fts.chunk(s, { chunkSize: 400 });
    assert.equal(ours.length, Math.ceil(s.length / 400));
    ours.forEach((c, i) => writeFileSync(path.join(chunkDir, `chunk_${String(i + 1).padStart(4, '0')}.txt`), c));
    py('unchunk', chunkDir, '-o', path.join(dir, 'rebuilt.txt'));
    assert.equal(readFileSync(path.join(dir, 'rebuilt.txt'), 'utf8'), s);

    // Python chunks -> JS reassemble, shuffled
    const enc = path.join(dir, 'encoded.txt');
    writeFileSync(enc, s);
    const pyDir = path.join(dir, 'pychunks');
    py('chunk', enc, '--size', '333', '-o', pyDir);
    const theirs = readdirSync(pyDir).map((f) => readFileSync(path.join(pyDir, f), 'utf8'));
    theirs.sort(() => Math.random() - 0.5);
    assert.equal(fts.reassemble(theirs), s);
  });

  test('missing, mixed and malformed chunks are reported', () => {
    const s = 'x'.repeat(1000);
    const a = fts.chunk(s, { chunkSize: 100, sessionId: 'aaaa1111' });
    assert.throws(() => fts.reassemble(a.filter((_, i) => i !== 3 && i !== 7)), /Missing chunk\(s\): \[4, 8\]/);
    const b = fts.chunk(s, { chunkSize: 100, sessionId: 'bbbb2222' });
    assert.throws(() => fts.reassemble([...a.slice(0, 5), ...b.slice(5)]), /multiple sessions/);
    assert.throws(() => fts.reassemble(['FTS1|nope']), /Not a chunk record/);
    assert.throws(() => fts.reassemble(['FTS1C|s|0/3|x']), /Bad chunk index/);
  });

  test('tampering and malformed strings are rejected', () => {
    const s = fts.encode(Buffer.from('important contract text, version 1'), { filename: 'c.txt', compress: false });
    const [magic, meta, payload] = s.split('|');
    const flipped = payload[0] === 'A' ? `B${payload.slice(1)}` : `A${payload.slice(1)}`;
    assert.throws(() => fts.decode(`${magic}|${meta}|${flipped}`), /Integrity check failed/);
    assert.throws(() => fts.decode(`FTS2|${meta}|${payload}`), /Unrecognized format magic/);
    assert.throws(() => fts.decode('just text'), /Malformed string/);
    assert.throws(() => fts.decode(`FTS1|!!!|${payload}`), /Malformed metadata/);
    assert.throws(() => fts.decode(`FTS1|${meta}|${payload.slice(0, -4)}`), /Size mismatch|Integrity/);
    assert.throws(() => fts.base45Decode('AB~'), /Invalid base45 character/);
    assert.throws(() => fts.base45Decode('A~'), /Invalid base45 character/, 'tail is validated too');
    assert.throws(() => fts.base45Decode('ABCD'), /length/);
    assert.throws(() => fts.base45Decode(':::'), /out of range/);
  });

  test('hardening: a crafted file name cannot escape the target folder', () => {
    const body = Buffer.from('owned');
    for (const evil of ['../../.bashrc', '/etc/passwd', '..\\..\\win.ini', '..', '']) {
      const s = fts.encode(body, { filename: evil, compress: false });
      const out = fts.decode(s);
      assert.ok(!out.filename.includes('/') && !out.filename.includes('\\') && out.filename !== '..', evil);
    }
    assert.equal(fts.decode(fts.encode(body, { filename: '../../.bashrc', compress: false })).filename, '.bashrc');
  });

  test('hardening: a gzip bomb with a small declared size is stopped', () => {
    const bomb = gzipSync(Buffer.alloc(50 * 1024 * 1024)); // 50 MB of zeros, ~50 KB compressed
    const meta = Buffer.from(
      JSON.stringify({ filename: 'x', size: 10, sha256: '0'.repeat(64), compressed: true, encoding: 'base64' }),
    ).toString('base64url');
    assert.throws(() => fts.decode(`FTS1|${meta}|${bomb.toString('base64')}`), /exceeds the declared size/);
    const huge = Buffer.from(
      JSON.stringify({ filename: 'x', size: 10 ** 12, sha256: '0'.repeat(64), compressed: true, encoding: 'base64' }),
    ).toString('base64url');
    assert.throws(() => fts.decode(`FTS1|${huge}|AAAA`), /too large/);
  });
});
