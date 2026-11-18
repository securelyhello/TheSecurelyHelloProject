// One authenticated WebSocket per client device (GET /api/ws, Bearer token).
//
// Client → server frames
//   {type:'signal', to, to_device, session_id, kind:'offer'|'answer'|'ice'|'bye', sdp?, candidate?, reason?}
//   {type:'relay_ack', ids:[uuid…]}
//   {type:'presence', state:'online'|'away'}
//   {type:'ping'}
//
// Server → client frames
//   {type:'hello', user_id, device_id, online:[contact ids currently online]}
//   {type:'signal', from, from_device, session_id, kind, sdp?, candidate?, reason?}
//   {type:'signal_error', to, to_device, session_id, reason:'offline'|'not_contacts'}
//   {type:'presence', user_id, online, last_seen}
//   {type:'contact_request', request}            new incoming request
//   {type:'contact_request_update', request}     our request accepted / rejected / cancelled
//   {type:'contact_removed', user_id}
//   {type:'devices_changed', user_id}           a contact (or you) added / removed a device
//   {type:'prekeys_low', remaining}              upload more one-time prekeys
//   {type:'relay', message:{id, sender_id, sender_device, envelope, created_at}}
//   {type:'pong'} | {type:'error', code, message?}
//
// A socket belongs to one device (the one its session registered). Relay
// pushes and signaling are addressed to devices; presence stays per user.
// Signaling is forwarded in memory only: nothing about SDP or ICE is stored.
// It is only forwarded between accepted contacts, and `from`/`from_device`
// are always the authenticated sender. Frame handling talks to Redis (caches, presence,
// relay acks), not to Postgres, except on a cold contact-cache miss.
//
// Routing is in-process: run ONE server instance (see DEPLOY.md).
import { WebSocketServer } from 'ws';

import { bearerToken, clientIp } from './http.js';
import { hashToken } from './security.js';
import { isUuid } from './validate.js';

const MAX_FRAME_BYTES = 64 * 1024;
const HEARTBEAT_MS = 30_000;
export const WS_PATH = '/api/ws';

export class RealtimeHub {
  /**
   * @param {object} deps
   * @param {import('./services.js').Services} deps.services
   * @param {import('./hotstore.js').HotStore} deps.store
   * @param {import('./ratelimit.js').RateLimits} deps.limits
   */
  constructor({ services, store, limits, trustProxyHops = 0, log }) {
    this.services = services;
    this.store = store;
    this.limits = limits;
    this.trustProxyHops = trustProxyHops;
    this.log = log;
    /** @type {Map<string, Set<import('ws').WebSocket>>} */
    this.sockets = new Map();
    this.closing = false;
    this.wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES });
    this.heartbeat = setInterval(() => this.#beat(), HEARTBEAT_MS);
    this.heartbeat.unref();
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  async handleUpgrade(req, socket, head) {
    const reject = (status, text) => {
      socket.write(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
      socket.destroy();
    };
    try {
      if (this.closing) return reject(503, 'Service Unavailable');
      const { pathname } = new URL(req.url, 'http://localhost');
      if (pathname !== WS_PATH) return reject(404, 'Not Found');
      if (!(await this.limits.take('wsConnect', clientIp(req, this.trustProxyHops)))) {
        return reject(429, 'Too Many Requests');
      }
      const token = bearerToken(req);
      const user = token ? await this.services.authenticate(token) : null;
      if (!user) return reject(401, 'Unauthorized');
      const tokenHash = hashToken(token).toString('hex');
      this.wss.handleUpgrade(req, socket, head, (ws) => this.#onConnection(ws, user, tokenHash));
    } catch (err) {
      this.log.error('ws upgrade failed', { error: err.message });
      reject(503, 'Service Unavailable');
    }
  }

  async #onConnection(ws, user, tokenHash) {
    const userId = user.id;
    ws.userId = userId;
    ws.deviceId = user.deviceId ?? null;
    ws.deviceApproved = false; // looked up below, before 'hello'
    ws.tokenHash = tokenHash;
    ws.away = false;
    ws.alive = true;
    const wasOnline = this.isOnline(userId);
    let set = this.sockets.get(userId);
    if (!set) {
      set = new Set();
      this.sockets.set(userId, set);
    }
    set.add(ws);

    ws.on('pong', () => {
      ws.alive = true;
    });
    ws.on('message', (data, isBinary) => {
      this.#onFrame(ws, data, isBinary).catch((err) => {
        this.log.error('ws frame failed', { user: userId, error: err.message });
        this.#send(ws, { type: 'error', code: 'internal' });
      });
    });
    ws.on('close', () => {
      const current = this.sockets.get(userId);
      current?.delete(ws);
      if (current && current.size === 0) this.sockets.delete(userId);
      if (!this.isOnline(userId)) {
        this.#wentOffline(userId).catch((err) => this.log.warn('presence offline failed', { error: err.message }));
      }
    });
    ws.on('error', () => {});

    try {
      if (ws.deviceId) ws.deviceApproved = await this.services.isDeviceApproved(ws.deviceId);
      if (!wasOnline && this.isOnline(userId)) await this.store.markOnline([userId]);
      const contacts = await this.services.contactIds(userId);
      const presence = await this.services.presence(contacts);
      this.#send(ws, {
        type: 'hello',
        user_id: userId,
        device_id: ws.deviceId,
        online: contacts.filter((id) => presence.get(id)?.online),
      });
      if (!wasOnline) this.#broadcastPresence(userId, contacts, true, null);
    } catch (err) {
      this.log.error('ws hello failed', { user: userId, error: err.message });
    }
  }

  async #wentOffline(userId) {
    const lastSeen = await this.store.markOffline(userId);
    if (this.closing) return; // shutting down: contacts' sockets are going too
    const contacts = await this.services.contactIds(userId);
    this.#broadcastPresence(userId, contacts, false, lastSeen);
  }

  #broadcastPresence(userId, contacts, online, lastSeen) {
    const frame = { type: 'presence', user_id: userId, online, last_seen: lastSeen };
    for (const id of contacts) this.sendTo(id, frame);
  }

  #beat() {
    const online = [];
    for (const [userId, set] of this.sockets) {
      for (const ws of set) {
        if (!ws.alive) {
          ws.terminate();
          continue;
        }
        ws.alive = false;
        try {
          ws.ping();
        } catch {
          /* closing */
        }
      }
      if (this.isOnline(userId)) online.push(userId);
    }
    // Refresh online TTLs so a crashed process stops claiming users are online.
    this.store.markOnline(online).catch((err) => this.log.warn('presence refresh failed', { error: err.message }));
  }

  // ---------------------------------------------------------------------------
  // Frames
  // ---------------------------------------------------------------------------

  async #onFrame(ws, data, isBinary) {
    const err = (code, extra = {}) => this.#send(ws, { type: 'error', code, ...extra });
    if (isBinary) return err('binary_not_supported');
    if (!(await this.limits.take('wsFrames', ws.userId))) return err('rate_limited');

    let msg;
    try {
      msg = JSON.parse(data.toString('utf8'));
    } catch {
      return err('malformed_json');
    }
    if (msg === null || typeof msg !== 'object' || Array.isArray(msg)) return err('malformed_frame');

    switch (msg.type) {
      case 'ping':
        return this.#send(ws, { type: 'pong' });
      case 'signal':
        return this.#onSignal(ws, msg);
      case 'relay_ack':
        return this.#onRelayAck(ws, msg);
      case 'presence':
        return this.#onPresence(ws, msg);
      default:
        return err('unknown_type');
    }
  }

  async #onSignal(ws, msg) {
    const from = ws.userId;
    const fail = (message) => this.#send(ws, { type: 'error', code: 'invalid_signal', message });
    const { to, to_device: toDevice, session_id: sessionId, kind } = msg;
    if (!ws.deviceId) return fail('register this device first');
    if (!ws.deviceApproved) return fail('this device is waiting for approval');
    if (!isUuid(to) || !isUuid(toDevice) || !isUuid(sessionId)) {
      return fail('to, to_device and session_id must be UUIDs');
    }
    const target = to.toLowerCase();
    const targetDevice = toDevice.toLowerCase();
    if (target === from) return fail('cannot signal yourself');

    const out = { type: 'signal', from, from_device: ws.deviceId, session_id: sessionId.toLowerCase(), kind };
    switch (kind) {
      case 'offer':
      case 'answer':
        if (typeof msg.sdp !== 'string' || msg.sdp.length < 1 || msg.sdp.length > 32_768) {
          return fail('sdp must be a string of at most 32768 characters');
        }
        out.sdp = msg.sdp;
        break;
      case 'ice': {
        const c = msg.candidate;
        if (
          c === null ||
          typeof c !== 'object' ||
          typeof c.candidate !== 'string' ||
          c.candidate.length > 2048 ||
          (c.sdpMid != null && (typeof c.sdpMid !== 'string' || c.sdpMid.length > 64)) ||
          (c.sdpMLineIndex != null &&
            (!Number.isInteger(c.sdpMLineIndex) || c.sdpMLineIndex < 0 || c.sdpMLineIndex > 1024))
        ) {
          return fail('invalid ICE candidate');
        }
        out.candidate = {
          candidate: c.candidate,
          sdpMid: c.sdpMid ?? null,
          sdpMLineIndex: c.sdpMLineIndex ?? null,
        };
        break;
      }
      case 'bye':
        if (msg.reason != null && (typeof msg.reason !== 'string' || msg.reason.length > 64)) {
          return fail('invalid reason');
        }
        if (msg.reason) out.reason = msg.reason;
        break;
      default:
        return fail('kind must be offer, answer, ice or bye');
    }

    const error = (reason) =>
      this.#send(ws, { type: 'signal_error', to: target, to_device: targetDevice, session_id: out.session_id, reason });
    if (!(await this.services.areContacts(from, target))) return error('not_contacts');
    if (this.sendToDevice(target, targetDevice, out) === 0) error('offline');
  }

  async #onRelayAck(ws, msg) {
    const ids = msg.ids;
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > 200 || !ids.every(isUuid)) {
      return this.#send(ws, { type: 'error', code: 'invalid_ack', message: 'ids must be 1-200 UUIDs' });
    }
    if (!ws.deviceId) return;
    await this.store.relayAck(ws.deviceId, ids.map((id) => id.toLowerCase()));
  }

  async #onPresence(ws, msg) {
    if (msg.state !== 'online' && msg.state !== 'away') {
      return this.#send(ws, { type: 'error', code: 'invalid_presence' });
    }
    const before = this.isOnline(ws.userId);
    ws.away = msg.state === 'away';
    const after = this.isOnline(ws.userId);
    if (before === after) return;
    if (after) {
      await this.store.markOnline([ws.userId]);
      this.#broadcastPresence(ws.userId, await this.services.contactIds(ws.userId), true, null);
    } else {
      await this.#wentOffline(ws.userId);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers used by the HTTP routes
  // ---------------------------------------------------------------------------

  /** A user is online while at least one of their sockets is not "away". */
  isOnline(userId) {
    const set = this.sockets.get(userId);
    if (!set) return false;
    for (const ws of set) if (!ws.away) return true;
    return false;
  }

  /** Sends [frame] to every socket of [userId]; returns how many got it. */
  sendTo(userId, frame) {
    const set = this.sockets.get(userId);
    if (!set) return 0;
    const payload = JSON.stringify(frame);
    let n = 0;
    for (const ws of set) {
      if (ws.readyState === ws.OPEN) {
        ws.send(payload);
        n++;
      }
    }
    return n;
  }

  /** Sends [frame] to the sockets of one device; returns how many got it. */
  sendToDevice(userId, deviceId, frame) {
    const set = this.sockets.get(userId);
    if (!set) return 0;
    const payload = JSON.stringify(frame);
    let n = 0;
    for (const ws of set) {
      if (ws.deviceId === deviceId && ws.readyState === ws.OPEN) {
        ws.send(payload);
        n++;
      }
    }
    return n;
  }

  /** Whether [deviceId] has a live socket (relay pushes reach it directly). */
  isDeviceConnected(userId, deviceId) {
    for (const ws of this.sockets.get(userId) ?? []) {
      if (ws.deviceId === deviceId && ws.readyState === ws.OPEN) return true;
    }
    return false;
  }

  /** A session registered its device after opening its socket. */
  bindDevice(userId, token, deviceId, approved = false) {
    const hash = hashToken(token).toString('hex');
    for (const ws of this.sockets.get(userId) ?? []) {
      if (ws.tokenHash === hash) {
        ws.deviceId = deviceId;
        ws.deviceApproved = approved;
      }
    }
  }

  /** A pending device was approved (or recovered). */
  setDeviceApproved(userId, deviceId) {
    for (const ws of this.sockets.get(userId) ?? []) {
      if (ws.deviceId === deviceId) ws.deviceApproved = true;
    }
  }

  /** Closes the sockets of one device (device removed). */
  disconnectDevice(userId, deviceId, code = 4004, reason = 'device removed') {
    for (const ws of this.sockets.get(userId) ?? []) {
      if (ws.deviceId === deviceId) ws.close(code, reason);
    }
  }

  /** Closes the sockets opened with these sessions ([hashes]: SHA-256 buffers). */
  disconnectSessions(userId, hashes, code = 4001, reason = 'session ended') {
    const wanted = new Set(hashes.map((h) => Buffer.from(h).toString('hex')));
    for (const ws of this.sockets.get(userId) ?? []) {
      if (wanted.has(ws.tokenHash)) ws.close(code, reason);
    }
  }

  /** Closes every socket of [userId] (account deletion). */
  disconnectUser(userId, code = 4001, reason = 'session ended') {
    for (const ws of this.sockets.get(userId) ?? []) ws.close(code, reason);
  }

  get connectionCount() {
    let n = 0;
    for (const set of this.sockets.values()) n += set.size;
    return n;
  }

  #send(ws, frame) {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(frame));
  }

  /**
   * Graceful shutdown: refuse new upgrades, ask clients to reconnect later
   * (1001 "going away"), and give them [graceMs] to close cleanly.
   */
  async close(graceMs = 5000) {
    this.closing = true;
    clearInterval(this.heartbeat);
    const all = [...this.sockets.values()].flatMap((s) => [...s]);
    for (const ws of all) ws.close(1001, 'server restarting');
    const deadline = Date.now() + graceMs;
    while (this.connectionCount > 0 && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 50));
    }
    for (const ws of all) ws.terminate();
    this.sockets.clear();
    await new Promise((resolve) => this.wss.close(() => resolve()));
  }
}
