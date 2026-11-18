// Prometheus metrics for operators: GET /metrics with
// `Authorization: Bearer <METRICS_TOKEN>` (the route doesn't exist without
// the token set). Each instance reports its own numbers; scrape them all.
//
// Labels are route patterns and status codes only, never ids, usernames or
// anything a client sent.
import { timingSafeEqual } from 'node:crypto';

import { HttpError } from './validate.js';

const BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];

export class Metrics {
  constructor() {
    /** "method route status" → count */
    this.requests = new Map();
    /** route → {buckets: number[], sum, count} */
    this.durations = new Map();
    /** kind → count */
    this.events = new Map();
    this.startedAt = Date.now() / 1000;
  }

  observeRequest(method, route, status, ms) {
    const key = `${method} ${route} ${status}`;
    this.requests.set(key, (this.requests.get(key) ?? 0) + 1);
    let d = this.durations.get(route);
    if (!d) {
      d = { buckets: BUCKETS.map(() => 0), sum: 0, count: 0 };
      this.durations.set(route, d);
    }
    const s = ms / 1000;
    BUCKETS.forEach((b, i) => {
      if (s <= b) d.buckets[i]++;
    });
    d.sum += s;
    d.count++;
  }

  /** Counts an event such as `relay_enqueued` or `push_wake`. */
  count(kind, n = 1) {
    this.events.set(kind, (this.events.get(kind) ?? 0) + n);
  }

  /** The text exposition format. [gauges]: name → [help, value]. */
  render(gauges = {}) {
    const out = [];
    const esc = (v) => String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    out.push('# HELP sh_http_requests_total HTTP requests by route pattern and status.');
    out.push('# TYPE sh_http_requests_total counter');
    for (const [key, n] of this.requests) {
      const [method, route, status] = key.split(' ');
      out.push(`sh_http_requests_total{method="${method}",route="${esc(route)}",status="${status}"} ${n}`);
    }
    out.push('# HELP sh_http_request_duration_seconds Time to answer, by route pattern.');
    out.push('# TYPE sh_http_request_duration_seconds histogram');
    for (const [route, d] of this.durations) {
      const r = esc(route);
      BUCKETS.forEach((b, i) => out.push(`sh_http_request_duration_seconds_bucket{route="${r}",le="${b}"} ${d.buckets[i]}`));
      out.push(`sh_http_request_duration_seconds_bucket{route="${r}",le="+Inf"} ${d.count}`);
      out.push(`sh_http_request_duration_seconds_sum{route="${r}"} ${d.sum}`);
      out.push(`sh_http_request_duration_seconds_count{route="${r}"} ${d.count}`);
    }
    out.push('# HELP sh_events_total Relay, push and other events.');
    out.push('# TYPE sh_events_total counter');
    for (const [kind, n] of this.events) out.push(`sh_events_total{kind="${esc(kind)}"} ${n}`);
    for (const [name, [help, value]] of Object.entries(gauges)) {
      out.push(`# HELP ${name} ${help}`, `# TYPE ${name} gauge`, `${name} ${value}`);
    }
    const mem = process.memoryUsage();
    out.push('# TYPE process_resident_memory_bytes gauge', `process_resident_memory_bytes ${mem.rss}`);
    out.push('# TYPE nodejs_heap_used_bytes gauge', `nodejs_heap_used_bytes ${mem.heapUsed}`);
    const cpu = process.cpuUsage();
    out.push('# TYPE process_cpu_seconds_total counter', `process_cpu_seconds_total ${(cpu.user + cpu.system) / 1e6}`);
    out.push('# TYPE process_start_time_seconds gauge', `process_start_time_seconds ${this.startedAt}`);
    return `${out.join('\n')}\n`;
  }
}

/** Throws unless [header] is `Bearer <token>`; 404 when metrics are off. */
export function checkMetricsToken(token, header) {
  if (!token) throw new HttpError(404, 'not_found');
  const given = Buffer.from(String(header ?? '').replace(/^Bearer /, ''));
  const want = Buffer.from(token);
  if (given.length !== want.length || !timingSafeEqual(given, want)) {
    throw new HttpError(401, 'unauthorized', 'Metrics need the operator token');
  }
}
