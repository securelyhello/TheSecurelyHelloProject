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
// Several server instances can run side by side. Each keeps its own
// sockets, and records in Redis which users and devices it holds (HotStore:
// sockets, devloc, online). A frame or instruction for a socket on another
// instance goes over the Bus. Presence counts a user online while any
// instance holds a non-away socket of theirs.
import { randomUUID } from 'node:crypto';

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
  constructor({ services, store, limits, trustProxyHops = 0, log, bus = null, instanceId = randomUUID() }) {
    this.services = services;
    this.store = store;
    this.limits = limits;
    this.trustProxyHops = trustProxyHops;
    this.log = log;
    /** @type {import('./bus.js').Bus | null} */
    this.bus = bus;
    this.instanceId = instanceId;
    /** @type {Map<string, Set<import('ws').WebSocket>>} */
    this.sockets = new Map();
    this.closing = false;
    this.wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES });
    this.heartbeat = setInterval(() => this.#beat(), HEARTBEAT_MS);
    this.heartbeat.unref();
  }

  // Connection lifecycle

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
      this.#afterClose(userId, ws.deviceId).catch((err) =>
        this.log.warn('presence offline failed', { error: err.message }),
      );
    });
    ws.on('error', () => {});

    try {
      if (ws.deviceId) ws.deviceApproved = await this.services.isDeviceApproved(ws.deviceId);
      await this.store.noteSockets([userId], this.instanceId);
      if (ws.deviceId) await this.store.noteDevices([ws.deviceId], this.instanceId);
      // Online here may not be news: another instance can hold their other device.
      const cameOnline =
        !wasOnline && this.isOnline(userId) && (await this.store.markOnline([userId], this.instanceId)).length > 0;
      const contacts = await this.services.contactIds(userId);
      const presence = await this.services.presence(contacts);
      this.#send(ws, {
        type: 'hello',
        user_id: userId,
        device_id: ws.deviceId,
        online: contacts.filter((id) => presence.get(id)?.online),
      });
      if (cameOnline) this.#broadcastPresence(userId, contacts, true, null);
    } catch (err) {
      this.log.error('ws hello failed', { user: userId, error: err.message });
    }
  }

  async #afterClose(userId, deviceId) {
    if (!this.isOnline(userId)) await this.#wentOffline(userId);
    if (!this.sockets.has(userId)) await this.store.dropSockets(userId, this.instanceId);
    if (deviceId && !this.#hasDevice(userId, deviceId)) await this.store.dropDevice(deviceId, this.instanceId);
  }

  async #wentOffline(userId) {
    const lastSeen = await this.store.markOffline(userId, this.instanceId);
    if (!lastSeen) return; // still online through another instance
    if (this.closing) return; // shutting down: contacts' sockets are going too
    const contacts = await this.services.contactIds(userId);
    this.#broadcastPresence(userId, contacts, false, lastSeen);
  }

  #hasDevice(userId, deviceId) {
    for (const ws of this.sockets.get(userId) ?? []) if (ws.deviceId === deviceId) return true;
    return false;
  }

  #broadcastPresence(userId, contacts, online, lastSeen) {
    const frame = { type: 'presence', user_id: userId, online, last_seen: lastSeen };
    for (const id of contacts) this.sendTo(id, frame);
  }

  #beat() {
    const online = [];
    const devices = [];
    for (const [userId, set] of this.sockets) {
      for (const ws of set) {
        if (ws.deviceId) devices.push(ws.deviceId);
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
    // Refresh our claims, so a crashed instance stops claiming anyone.
    Promise.all([
      this.store.markOnline(online, this.instanceId),
      this.store.noteSockets([...this.sockets.keys()], this.instanceId),
      this.store.noteDevices(devices, this.instanceId),
    ]).catch((err) => this.log.warn('presence refresh failed', { error: err.message }));
  }

  // Frames

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
    if ((await this.deliverToDevice(target, targetDevice, out)) === 0) error('offline');
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
      const fresh = await this.store.markOnline([ws.userId], this.instanceId);
      if (fresh.length) this.#broadcastPresence(ws.userId, await this.services.contactIds(ws.userId), true, null);
    } else {
      await this.#wentOffline(ws.userId);
    }
  }

  // Helpers used by the HTTP routes. Each acts here and, through the bus,
  // on the other instances that hold sockets of the user.

  /** A user is online here while at least one of their sockets is not "away". */
  isOnline(userId) {
    const set = this.sockets.get(userId);
    if (!set) return false;
    for (const ws of set) if (!ws.away) return true;
    return false;
  }

  /** Sends [frame] to every socket of [userId], on any instance. Returns
   * how many sockets here got it. */
  sendTo(userId, frame) {
    this.#elsewhere(userId, { op: 'frame', u: userId, f: frame });
    return this.#sendLocal(userId, frame);
  }

  /** Sends [frame] to one device's sockets. Resolves to how many got it
   * (1 when it went to the instance holding that device). */
  async deliverToDevice(userId, deviceId, frame) {
    const here = this.#sendLocalDevice(userId, deviceId, frame);
    if (here > 0 || !this.bus) return here;
    const where = await this.store.deviceInstance(deviceId);
    if (!where || where === this.instanceId) return 0;
    await this.bus.send(where, { op: 'device', u: userId, d: deviceId, f: frame });
    return 1;
  }

  /** Whether [deviceId] has a live socket on any instance (relay pushes reach it directly). */
  async isDeviceConnected(userId, deviceId) {
    for (const ws of this.sockets.get(userId) ?? []) {
      if (ws.deviceId === deviceId && ws.readyState === ws.OPEN) return true;
    }
    if (!this.bus) return false;
    const where = await this.store.deviceInstance(deviceId);
    return where != null && where !== this.instanceId;
  }

  /** A session registered its device after opening its socket. */
  bindDevice(userId, token, deviceId, approved = false) {
    const hash = hashToken(token).toString('hex');
    this.#elsewhere(userId, { op: 'bind', u: userId, h: hash, d: deviceId, a: approved });
    this.#bindLocal(userId, hash, deviceId, approved);
  }

  /** A pending device was approved (or recovered). */
  setDeviceApproved(userId, deviceId) {
    this.#elsewhere(userId, { op: 'approved', u: userId, d: deviceId });
    this.#approvedLocal(userId, deviceId);
  }

  /** Closes the sockets of one device (device removed). */
  disconnectDevice(userId, deviceId, code = 4004, reason = 'device removed') {
    this.#elsewhere(userId, { op: 'closeDevice', u: userId, d: deviceId, code, reason });
    this.#closeLocal(userId, (ws) => ws.deviceId === deviceId, code, reason);
  }

  /** Closes the sockets opened with these sessions ([hashes]: SHA-256 buffers). */
  disconnectSessions(userId, hashes, code = 4001, reason = 'session ended') {
    const wanted = hashes.map((h) => Buffer.from(h).toString('hex'));
    this.#elsewhere(userId, { op: 'closeSessions', u: userId, h: wanted, code, reason });
    const set = new Set(wanted);
    this.#closeLocal(userId, (ws) => set.has(ws.tokenHash), code, reason);
  }

  /** Closes every socket of [userId] (account deletion). */
  disconnectUser(userId, code = 4001, reason = 'session ended') {
    this.#elsewhere(userId, { op: 'closeUser', u: userId, code, reason });
    this.#closeLocal(userId, () => true, code, reason);
  }

  /** A message from another instance (see Bus). */
  onBusMessage(msg) {
    const u = msg?.u;
    if (typeof u !== 'string') return;
    switch (msg.op) {
      case 'frame':
        this.#sendLocal(u, msg.f);
        break;
      case 'device':
        this.#sendLocalDevice(u, msg.d, msg.f);
        break;
      case 'bind':
        this.#bindLocal(u, msg.h, msg.d, msg.a === true);
        break;
      case 'approved':
        this.#approvedLocal(u, msg.d);
        break;
      case 'closeDevice':
        this.#closeLocal(u, (ws) => ws.deviceId === msg.d, msg.code, msg.reason);
        break;
      case 'closeSessions': {
        const set = new Set(Array.isArray(msg.h) ? msg.h : []);
        this.#closeLocal(u, (ws) => set.has(ws.tokenHash), msg.code, msg.reason);
        break;
      }
      case 'closeUser':
        this.#closeLocal(u, () => true, msg.code, msg.reason);
        break;
    }
  }

  /** Runs [msg] on the other instances holding sockets of [userId]. */
  #elsewhere(userId, msg) {
    if (!this.bus) return;
    this.store
      .socketInstances(userId)
      .then(async (instances) => {
        for (const i of instances) if (i !== this.instanceId) await this.bus.send(i, msg);
      })
      .catch((err) => this.log.warn('bus send failed', { op: msg.op, error: err.message }));
  }

  #sendLocal(userId, frame) {
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

  #sendLocalDevice(userId, deviceId, frame) {
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

  #bindLocal(userId, hash, deviceId, approved) {
    let bound = false;
    for (const ws of this.sockets.get(userId) ?? []) {
      if (ws.tokenHash === hash) {
        ws.deviceId = deviceId;
        ws.deviceApproved = approved;
        bound = true;
      }
    }
    if (bound) {
      this.store
        .noteDevices([deviceId], this.instanceId)
        .catch((err) => this.log.warn('device location failed', { error: err.message }));
    }
  }

  #approvedLocal(userId, deviceId) {
    for (const ws of this.sockets.get(userId) ?? []) {
      if (ws.deviceId === deviceId) ws.deviceApproved = true;
    }
  }

  #closeLocal(userId, which, code, reason) {
    for (const ws of this.sockets.get(userId) ?? []) if (which(ws)) ws.close(code, reason);
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
