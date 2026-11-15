import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { createMailer, createMemoryMailer, templates } from '../src/mailer.js';

function captureLog() {
  const lines = [];
  const at = (level) => (msg, fields) => lines.push({ level, msg, ...fields });
  return { lines, log: { debug: at('debug'), info: at('info'), warn: at('warn'), error: at('error') } };
}

function fakeFetch(respond = () => new Response('{}', { status: 200 })) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return respond(url, init);
  };
  fn.calls = calls;
  return fn;
}

const MSG = {
  to: 'person@example.test',
  subject: 'Your code',
  text: 'Your code is 123456',
  html: '<p>Your code is <b>123456</b></p>',
  template: 'password_reset',
  userId: '00000000-0000-4000-8000-000000000001',
};

describe('mailer', () => {
  test('Resend: POSTs the documented JSON shape with a bearer key', async () => {
    const fetchImpl = fakeFetch();
    const { log } = captureLog();
    const m = createMailer({ provider: 'resend', from: 'Securely Hello <no-reply@thenn.in>', apiKey: 're_key', log, fetchImpl });
    const res = await m.send(MSG);
    assert.deepEqual(res, { ok: true, dryRun: false });
    assert.equal(fetchImpl.calls.length, 1);
    const { url, init, body } = fetchImpl.calls[0];
    assert.equal(url, 'https://api.resend.com/emails');
    assert.equal(init.method, 'POST');
    assert.equal(init.headers.Authorization, 'Bearer re_key');
    assert.equal(init.headers['Content-Type'], 'application/json');
    assert.ok(init.signal instanceof AbortSignal, 'requests have a timeout');
    assert.deepEqual(body, {
      from: 'Securely Hello <no-reply@thenn.in>',
      to: ['person@example.test'],
      subject: 'Your code',
      text: MSG.text,
      html: MSG.html,
    });
  });

  test('Brevo: POSTs the documented JSON shape with an api-key header and parsed sender', async () => {
    const fetchImpl = fakeFetch(() => new Response('{}', { status: 201 }));
    const { log } = captureLog();
    const m = createMailer({ provider: 'brevo', from: 'Securely Hello <no-reply@thenn.in>', apiKey: 'xkeysib', log, fetchImpl });
    assert.deepEqual(await m.send(MSG), { ok: true, dryRun: false });
    const { url, init, body } = fetchImpl.calls[0];
    assert.equal(url, 'https://api.brevo.com/v3/smtp/email');
    assert.equal(init.headers['api-key'], 'xkeysib');
    assert.deepEqual(body, {
      sender: { email: 'no-reply@thenn.in', name: 'Securely Hello' },
      to: [{ email: 'person@example.test' }],
      subject: 'Your code',
      textContent: MSG.text,
      htmlContent: MSG.html,
    });
  });

  test('Brevo: a bare address becomes the sender e-mail without a name', async () => {
    const fetchImpl = fakeFetch();
    const m = createMailer({ provider: 'brevo', from: 'no-reply@thenn.in', apiKey: 'k', log: captureLog().log, fetchImpl });
    await m.send(MSG);
    assert.deepEqual(fetchImpl.calls[0].body.sender, { email: 'no-reply@thenn.in' });
  });

  test('missing key or from: dry-run, one startup warning, no fetch', async () => {
    for (const cfg of [{ from: 'no-reply@thenn.in' }, { apiKey: 'k' }]) {
      const fetchImpl = fakeFetch();
      const { log, lines } = captureLog();
      const printed = [];
      const m = createMailer({ provider: 'resend', ...cfg, log, fetchImpl, print: (s) => printed.push(s) });
      assert.equal(lines.filter((l) => l.level === 'warn').length, 1);
      assert.deepEqual(await m.send(MSG), { ok: true, dryRun: true });
      await m.send(MSG);
      assert.equal(fetchImpl.calls.length, 0);
      assert.equal(lines.filter((l) => l.level === 'warn').length, 1, 'warned once, at startup');
      assert.equal(m.dryRun, true);
    }
  });

  test('unknown provider: dry-run with a warning', async () => {
    const fetchImpl = fakeFetch();
    const { log, lines } = captureLog();
    const m = createMailer({ provider: 'smtp', from: 'a@thenn.in', apiKey: 'k', log, fetchImpl, print: () => {} });
    assert.equal(lines.filter((l) => l.level === 'warn').length, 1);
    assert.deepEqual(await m.send(MSG), { ok: true, dryRun: true });
    assert.equal(fetchImpl.calls.length, 0);
  });

  test('provider "log" (the default) is a dry-run', async () => {
    const fetchImpl = fakeFetch();
    const m = createMailer({ log: captureLog().log, fetchImpl, print: () => {} });
    assert.deepEqual(await m.send(MSG), { ok: true, dryRun: true });
    assert.equal(fetchImpl.calls.length, 0);
  });

  test('provider "log" or unset: info in development, a warning in production', () => {
    const warns = (opts) => {
      const { log, lines } = captureLog();
      createMailer({ ...opts, log, print: () => {} });
      return lines.filter((l) => l.level === 'warn');
    };
    assert.equal(warns({ provider: 'log', production: false }).length, 0);
    assert.equal(warns({ production: false }).length, 0);
    for (const provider of ['log', '', undefined]) {
      const w = warns({ provider, production: true });
      assert.equal(w.length, 1, `provider=${provider}`);
      assert.match(w[0].msg, /dry-run/);
    }
  });

  test('EMAIL_API_KEY set while the provider is "log": an extra warning, key never logged', () => {
    for (const [production, expected] of [
      [false, 1],
      [true, 2],
    ]) {
      const { log, lines } = captureLog();
      const m = createMailer({ provider: 'log', apiKey: 're_secret_key', from: 'a@thenn.in', log, production });
      assert.equal(m.dryRun, true);
      const w = lines.filter((l) => l.level === 'warn');
      assert.equal(w.length, expected, `production=${production}`);
      assert.ok(w.some((l) => /EMAIL_API_KEY/.test(l.msg) && /EMAIL_PROVIDER/.test(l.msg)));
      assert.equal(JSON.stringify(lines).includes('re_secret_key'), false);
    }
    // A key with an unset provider is the same mistake.
    const { log, lines } = captureLog();
    createMailer({ apiKey: 'k', log, production: false });
    assert.ok(lines.some((l) => l.level === 'warn' && /EMAIL_API_KEY/.test(l.msg)));
  });

  test('development dry-run prints recipient and code to stdout', async () => {
    const printed = [];
    const m = createMailer({ provider: 'log', log: captureLog().log, production: false, print: (s) => printed.push(s) });
    await m.send(MSG);
    const out = printed.join('\n');
    assert.ok(out.includes('person@example.test'));
    assert.ok(out.includes('123456'));
  });

  test('production dry-run logs neither the code nor the address', async () => {
    const printed = [];
    const { log, lines } = captureLog();
    const m = createMailer({ provider: 'log', log, production: true, print: (s) => printed.push(s) });
    await m.send(MSG);
    assert.equal(printed.length, 0, 'nothing printed in production');
    const all = JSON.stringify(lines);
    assert.equal(all.includes('123456'), false);
    assert.equal(all.includes('person@example.test'), false);
    assert.ok(lines.some((l) => l.template === 'password_reset' && l.user_id === MSG.userId));
  });

  test('fetch rejecting or a 500 resolves {ok:false} and never throws; logs status only', async () => {
    const rejecting = fakeFetch(() => Promise.reject(new Error('network down for person@example.test')));
    const failing = fakeFetch(() => new Response('{"message":"boom person@example.test"}', { status: 500 }));
    for (const fetchImpl of [rejecting, failing]) {
      const { log, lines } = captureLog();
      const m = createMailer({ provider: 'resend', from: 'a@thenn.in', apiKey: 'secret_key', log, fetchImpl });
      assert.deepEqual(await m.send(MSG), { ok: false, dryRun: false });
      const all = JSON.stringify(lines);
      assert.equal(all.includes('person@example.test'), false);
      assert.equal(all.includes('123456'), false);
      assert.equal(all.includes('secret_key'), false);
    }
    const { log, lines } = captureLog();
    await createMailer({ provider: 'resend', from: 'a@thenn.in', apiKey: 'k', log, fetchImpl: failing }).send(MSG);
    assert.ok(lines.some((l) => l.status === 500));
  });

  test('templates contain the code in text and html', () => {
    for (const t of [templates.passwordReset('012345'), templates.verifyEmail('012345')]) {
      assert.equal(typeof t.subject, 'string');
      assert.ok(t.text.includes('012345'));
      assert.ok(t.html.includes('012345'));
    }
  });

  test('memory mailer records messages in its outbox', async () => {
    const m = createMemoryMailer();
    assert.deepEqual(await m.send(MSG), { ok: true, dryRun: false });
    assert.equal(m.outbox.length, 1);
    assert.equal(m.outbox[0].to, MSG.to);
  });
});
