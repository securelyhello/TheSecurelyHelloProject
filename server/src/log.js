// Structured JSON-lines logging to stdout/stderr (Docker / Coolify collect it).
//
// Rules: never log message envelopes, SDP/ICE, request bodies, passwords,
// tokens or their hashes, e-mail addresses or search terms. Log user ids,
// route patterns, status codes and timings only.

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40, silent: 100 };

function make(minLevel, sink) {
  const min = LEVELS[minLevel] ?? LEVELS.info;
  const emit = (level, msg, fields) => {
    if (LEVELS[level] < min) return;
    const line = JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields });
    sink(level, line);
  };
  return {
    debug: (msg, fields) => emit('debug', msg, fields),
    info: (msg, fields) => emit('info', msg, fields),
    warn: (msg, fields) => emit('warn', msg, fields),
    error: (msg, fields) => emit('error', msg, fields),
  };
}

const stdSink = (level, line) => (level === 'error' || level === 'warn' ? process.stderr : process.stdout).write(`${line}\n`);

export const logger = make(process.env.LOG_LEVEL || 'info', stdSink);
export const silentLogger = make('silent', () => {});
