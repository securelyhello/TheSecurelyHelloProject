// Transactional e-mail (password-reset and verification codes) over the
// provider's HTTPS API with plain fetch: no SMTP, no extra dependencies.
//
//   EMAIL_PROVIDER  resend | brevo | log (default log = dry-run, whatever else
//                   is set; logged as a warning in production)
//   EMAIL_FROM      "Name <addr>" or "addr"; must be on thenn.in itself (strict DMARC)
//   EMAIL_API_KEY   provider API key (secret)
//
// A missing key/from or an unknown provider falls back to dry-run with one
// warning at startup. send() never throws: it resolves {ok, dryRun}. Per
// log.js rules nothing here logs addresses, codes, bodies or keys; in
// development the dry-run prints recipient + text to stdout so codes can be
// typed in by hand.

const TIMEOUT_MS = 10_000;

const PROVIDERS = {
  resend: (msg, { from, apiKey }) => ({
    url: 'https://api.resend.com/emails',
    headers: { Authorization: `Bearer ${apiKey}` },
    body: { from, to: [msg.to], subject: msg.subject, text: msg.text, html: msg.html },
  }),
  brevo: (msg, { from, apiKey }) => ({
    url: 'https://api.brevo.com/v3/smtp/email',
    headers: { 'api-key': apiKey },
    body: {
      sender: parseAddress(from),
      to: [{ email: msg.to }],
      subject: msg.subject,
      textContent: msg.text,
      htmlContent: msg.html,
    },
  }),
};

/** "Name <addr>" → {email, name}; "addr" → {email}. */
export function parseAddress(value) {
  const m = /^\s*(.*?)\s*<([^<>\s]+)>\s*$/.exec(value ?? '');
  if (!m) return { email: String(value ?? '').trim() };
  const name = m[1].replace(/^"(.*)"$/, '$1').trim();
  return name ? { email: m[2], name } : { email: m[2] };
}

const defaultPrint = (line) => process.stdout.write(`${line}\n`);

/**
 * @param {{provider?: string, from?: string, apiKey?: string, log: object,
 *          fetchImpl?: typeof fetch, production?: boolean, print?: (s: string) => void}} opts
 */
export function createMailer({
  provider = 'log',
  from = '',
  apiKey = '',
  log,
  fetchImpl = globalThis.fetch,
  production = process.env.NODE_ENV === 'production',
  print = defaultPrint,
} = {}) {
  const name = String(provider || 'log').toLowerCase();
  const build = PROVIDERS[name];
  let dryRun = true;
  if (name === 'log') {
    // The default. In production this almost always means EMAIL_PROVIDER was
    // forgotten, so say it loudly: users never receive their codes.
    const msg = 'mailer: dry-run (EMAIL_PROVIDER=log or unset), no e-mail is delivered';
    if (production) log?.warn(msg);
    else log?.info(msg);
    if (apiKey) {
      log?.warn('mailer: EMAIL_API_KEY is set but EMAIL_PROVIDER is log/unset; set EMAIL_PROVIDER=resend or brevo to send');
    }
  } else if (!build) {
    log?.warn('mailer: unknown EMAIL_PROVIDER, falling back to dry-run', { provider: name.slice(0, 32) });
  } else if (!from || !apiKey) {
    log?.warn('mailer: EMAIL_FROM or EMAIL_API_KEY missing, falling back to dry-run', { provider: name });
  } else {
    dryRun = false;
  }

  async function send(msg) {
    const fields = { template: msg.template, user_id: msg.userId };
    if (dryRun) {
      if (production) {
        log?.info('mail dry-run', fields);
      } else {
        print(`[mailer dry-run] to=${msg.to} template=${msg.template}\n${msg.text}`);
      }
      return { ok: true, dryRun: true };
    }
    try {
      const req = build(msg, { from, apiKey });
      const res = await fetchImpl(req.url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...req.headers },
        body: JSON.stringify(req.body),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      // Drain the body so the connection is reused; never log it.
      await res.arrayBuffer().catch(() => {});
      if (!res.ok) {
        log?.warn('mail rejected', { ...fields, provider: name, status: res.status });
        return { ok: false, dryRun: false };
      }
      log?.info('mail sent', { ...fields, provider: name, status: res.status });
      return { ok: true, dryRun: false };
    } catch (err) {
      // err.message may echo request details; log only its class.
      log?.warn('mail failed', { ...fields, provider: name, error: err?.name ?? 'Error' });
      return { ok: false, dryRun: false };
    }
  }

  return { send, dryRun, provider: name };
}

/** Test double: records every message instead of sending it. */
export function createMemoryMailer() {
  const outbox = [];
  return {
    outbox,
    dryRun: false,
    provider: 'memory',
    async send(msg) {
      outbox.push({ ...msg });
      return { ok: true, dryRun: false };
    },
  };
}

const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

function codeMail({ subject, intro, code, minutes, outro }) {
  const text = [
    intro,
    '',
    `    ${code}`,
    '',
    `The code expires in ${minutes} minutes and can be used once.`,
    outro,
    '',
    '— Securely Hello',
  ].join('\n');
  const html = `<!doctype html><html><body style="font-family:system-ui,sans-serif;line-height:1.5;color:#111">
<p>${escapeHtml(intro)}</p>
<p style="font-size:28px;font-weight:700;letter-spacing:6px;font-family:ui-monospace,monospace">${escapeHtml(code)}</p>
<p>The code expires in ${minutes} minutes and can be used once.</p>
<p>${escapeHtml(outro)}</p>
<p style="color:#666">— Securely Hello</p>
</body></html>`;
  return { subject, text, html };
}

export const templates = {
  passwordReset: (code) =>
    codeMail({
      subject: 'Your Securely Hello password reset code',
      intro: 'Enter this code in the Securely Hello app to choose a new password:',
      code,
      minutes: 15,
      outro: "If you didn't ask to reset your password, ignore this e-mail; your password stays the same.",
    }),
  verifyEmail: (code) =>
    codeMail({
      subject: 'Verify your e-mail for Securely Hello',
      intro: 'Enter this code in the Securely Hello app to verify your e-mail address:',
      code,
      minutes: 30,
      outro: "If you didn't request this, you can ignore this e-mail.",
    }),
};
