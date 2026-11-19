// Outgoing e-mail: verification and password-reset codes only.
//
// MAIL_TRANSPORT
//   smtp  send through SMTP_URL (smtp://user:pass@host:587, smtps://… for TLS)
//   file  write each message as JSON into MAIL_FILE_DIR (integration tests)
//   log   print the message to stderr (local development only)
//   none  e-mail is disabled; verification is optional and reset unavailable
//
// Default: smtp when SMTP_URL is set, otherwise log outside production and
// none in production (codes must never end up in production logs).
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

import nodemailer from 'nodemailer';

export function mailTransportName(env = process.env) {
  const explicit = (env.MAIL_TRANSPORT ?? '').trim().toLowerCase();
  if (explicit) return explicit;
  if (env.SMTP_URL) return 'smtp';
  return env.NODE_ENV === 'production' ? 'none' : 'log';
}

/**
 * @returns {{transport: string, enabled: boolean, send(msg: {to: string, subject: string, text: string, html?: string}): Promise<void>}}
 */
export function createMailer(env = process.env) {
  const transport = mailTransportName(env);
  const from = env.MAIL_FROM || 'Securely Hello <no-reply@localhost>';

  switch (transport) {
    case 'smtp': {
      if (!env.SMTP_URL) throw new Error('MAIL_TRANSPORT=smtp needs SMTP_URL');
      const smtp = nodemailer.createTransport(env.SMTP_URL);
      return {
        transport,
        enabled: true,
        async send(msg) {
          await smtp.sendMail({ from, ...msg });
        },
      };
    }
    case 'file': {
      const dir = env.MAIL_FILE_DIR;
      if (!dir) throw new Error('MAIL_TRANSPORT=file needs MAIL_FILE_DIR');
      return {
        transport,
        enabled: true,
        async send(msg) {
          await mkdir(dir, { recursive: true });
          const name = `${Date.now()}-${randomUUID()}.json`;
          await writeFile(path.join(dir, name), JSON.stringify({ from, ...msg }));
        },
      };
    }
    case 'log':
      return {
        transport,
        enabled: true,
        async send(msg) {
          process.stderr.write(`[mail:dev] to=${msg.to} subject="${msg.subject}"\n${msg.text}\n`);
        },
      };
    case 'none':
      return {
        transport,
        enabled: false,
        async send() {
          throw new Error('e-mail is disabled (MAIL_TRANSPORT=none)');
        },
      };
    default:
      throw new Error(`Unknown MAIL_TRANSPORT "${transport}"`);
  }
}

/** Records messages in memory (tests). */
export function captureMailer() {
  const sent = [];
  return {
    transport: 'capture',
    enabled: true,
    sent,
    async send(msg) {
      sent.push(msg);
    },
    /** The 6-digit code in the latest message to [to]. */
    lastCode(to) {
      const msg = [...sent].reverse().find((m) => m.to.toLowerCase() === to.toLowerCase());
      return msg ? /\b(\d{6})\b/.exec(msg.text)?.[1] ?? null : null;
    },
  };
}

const PURPOSE_TEXT = {
  verify: {
    subject: 'Your Securely Hello verification code',
    intro: 'Use this code to confirm your e-mail address:',
  },
  email: {
    subject: 'Confirm your new e-mail for Securely Hello',
    intro: 'Use this code to make this your Securely Hello e-mail address:',
  },
  reset: {
    subject: 'Reset your Securely Hello password',
    intro: 'Use this code to choose a new password:',
  },
  device: {
    subject: 'Approve a new device for Securely Hello',
    intro:
      'Someone (hopefully you) wants to recover your account on a new device. Using this code signs out and ' +
      'removes all your other devices. Code:',
  },
};

export function codeEmail(purpose, to, code, minutes) {
  const t = PURPOSE_TEXT[purpose];
  const text =
    `${t.intro}\n\n    ${code}\n\n` +
    `It expires in ${minutes} minutes. If you didn't ask for this, you can ignore this e-mail; ` +
    'nobody can use the code without access to your inbox.\n\n' +
    'Securely Hello will never ask you for this code.';
  const html =
    `<p>${t.intro}</p>` +
    `<p style="font-size:28px;letter-spacing:6px;font-family:monospace"><b>${code}</b></p>` +
    `<p>It expires in ${minutes} minutes. If you didn't ask for this, you can ignore this e-mail.</p>` +
    '<p style="color:#888">Securely Hello will never ask you for this code.</p>';
  return { to, subject: t.subject, text, html };
}
