// Messages between server instances, over Redis pub/sub.
//
// Each instance listens on its own channel. The realtime hub uses this to
// reach sockets held by another instance: a frame for a user or device,
// or an instruction such as "close this device's socket". Locations come
// from Redis (see HotStore: sockets, devloc). Pub/sub is fire-and-forget:
// a frame lost while an instance restarts is the same as one sent to a
// socket that just dropped, and clients recover by draining the relay
// queue when they reconnect.

export class Bus {
  /**
   * @param {object} deps
   * @param {import('ioredis').Redis} deps.redis  the shared connection (publishing)
   * @param {string} deps.instanceId
   * @param {string} [deps.prefix]
   */
  constructor({ redis, instanceId, prefix = 'sh:', log }) {
    this.pub = redis;
    this.instanceId = instanceId;
    this.prefix = prefix;
    this.log = log;
    this.sub = null;
  }

  channel(instanceId) {
    return `${this.prefix}bus:${instanceId}`;
  }

  /** Subscribes; [onMessage] gets each message sent to this instance. */
  async start(onMessage) {
    // A subscribed connection can't run other commands: use its own.
    this.sub = this.pub.duplicate();
    this.sub.on('message', (_channel, raw) => {
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        return;
      }
      try {
        onMessage(msg);
      } catch (err) {
        this.log?.warn('bus message failed', { op: msg?.op, error: err.message });
      }
    });
    await this.sub.subscribe(this.channel(this.instanceId));
  }

  async send(instanceId, msg) {
    await this.pub.publish(this.channel(instanceId), JSON.stringify(msg));
  }

  async close() {
    const sub = this.sub;
    this.sub = null;
    if (sub) await sub.quit().catch(() => sub.disconnect());
  }
}
