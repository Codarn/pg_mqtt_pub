# ADR-001: Hybrid Delivery Model (Hot/Cold Path)

**Status:** Accepted  
**Date:** 2026-02-13  
**Deciders:** @fsjobeck, @crhaglun 

## Context

pg_mqtt_pub needs to publish MQTT messages from PostgreSQL triggers, SQL functions, and pg_cron jobs. The core tension is between **latency** (triggers should not slow down DML) and **durability** (messages should not be silently lost during broker outages).

Three approaches were considered:

1. **Ring buffer only** — shared memory, sub-millisecond, but volatile. Messages are lost on broker disconnect, Postgres crash, or restart.
2. **Outbox table only** — WAL-backed, crash-safe, but adds 2-10ms of write latency to every trigger fire due to the additional table INSERT and WAL fsync.
3. **Hybrid model** — ring buffer when healthy, outbox table during failures. Optimizes for the common case while providing durability when it matters.

## Decision

We implement a **hybrid hot/cold delivery model** with automatic failover.

### Architecture

```
                      ┌─────────────────────┐
                      │  delivery_mode flag  │
                      │  (shared memory)     │
                      └──────────┬──────────┘
                                 │
             ┌───── HOT ─────────┼────── COLD ──────┐
             │                   │                   │
             ▼                   │                   ▼
   ┌──────────────────┐         │        ┌───────────────────┐
   │  Ring Buffer      │         │        │  mqtt_pub.outbox   │
   │  (shared memory)  │         │        │  (WAL-backed table)│
   │  ~0.1ms latency   │         │        │  ~2-5ms latency    │
   │  volatile          │         │        │  crash-safe        │
   └────────┬─────────┘         │        └────────┬──────────┘
            │                   │                  │
            └───────────────────┼──────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  Background Worker     │
                    │  drain order:          │
                    │    1. outbox (FIFO)    │
                    │    2. ring buffer      │
                    └───────────┬───────────┘
                                │
                                ▼
                         MQTT Broker(s)
```

### Mode Transitions

```
                    ┌───────────────────┐
         ┌─────────│     HOT MODE       │
         │         │  (ring buffer)     │
         │         └─────────┬─────────┘
         │                   │
         │    broker disconnects OR
         │    ring buffer full (spill)
         │                   │
         │                   ▼
         │         ┌───────────────────┐
         │         │    COLD MODE       │
         └─────────│  (outbox table)   │
   all brokers     └───────────────────┘
   reconnected
   AND outbox
   fully drained
```

**HOT → COLD** triggers:
- Any broker connection drops (on_disconnect callback)
- Ring buffer is full (spill to outbox instead of blocking/dropping)

**COLD → HOT** triggers (ALL conditions must be true):
- Every configured broker is connected
- The outbox table is completely empty (all pending rows drained)

The requirement that the outbox be fully drained before switching to HOT is critical for **message ordering**. Outbox messages were enqueued during the outage and must be delivered before any new ring buffer messages.

### Message Flow During Outage

```
Time ──────────────────────────────────────────────────────►

t0: Broker connected. HOT mode. Trigger fires → ring buffer → broker. ✓
t1: Broker disconnects. Worker sets COLD mode.
t2: Trigger fires → outbox row #1 (WAL-durable)
t3: Trigger fires → outbox row #2
t4: Broker reconnects. Worker begins outbox drain.
t5: Worker publishes outbox row #1 → broker. DELETE row #1. ✓
t6: Trigger fires → outbox row #3 (still COLD, outbox not empty)
t7: Worker publishes outbox row #2 → broker. DELETE row #2. ✓
t8: Worker publishes outbox row #3 → broker. DELETE row #3. ✓
t9: Outbox empty + all connected → switch to HOT.
t10: Trigger fires → ring buffer → broker. ✓
```

Messages #1, #2, #3 are delivered in order, and no message written during the outage is lost.

## Poison Message Guardrails

A poison message is one that consistently fails to publish — malformed topic, oversized payload, broker-side ACL rejection, or a bug in the payload that triggers a broker disconnect.

Without guardrails, a poison message would block the outbox drain forever: the worker retries it, fails, retries again, ad infinitum, while all messages behind it in the queue pile up.

### Strategy: Exponential Backoff + Dead-Lettering

```
Attempt 1: fail → retry in 1s
Attempt 2: fail → retry in 2s
Attempt 3: fail → retry in 4s
Attempt 4: fail → retry in 8s
Attempt 5: fail → DEAD-LETTER (move to mqtt_pub.dead_letters)
```

Each outbox row tracks:
- `attempts` — incremented on each failure
- `next_retry_at` — set to `now() + backoff_ms` on failure

The worker's drain query skips rows where `next_retry_at > now()`, so a failing message doesn't block other messages from being delivered. This is the key insight: **poison messages are time-displaced rather than queue-blocking**.

### Dead Letter Table

Messages that exceed `pg_mqtt_pub.poison_max_attempts` (default: 5) are moved to `mqtt_pub.dead_letters` with full diagnostic context:

```sql
SELECT id, topic, attempts, last_error, dead_lettered_at
FROM mqtt_pub.dead_letters
ORDER BY dead_lettered_at DESC;
```

Dead letters are:
- **Retained** for `pg_mqtt_pub.dead_letter_retain_days` (default: 30)
- **Auto-pruned** by the background worker hourly
- **Replayable** via `mqtt_pub.replay_dead_letters()` which moves them back to the outbox with `attempts = 0`

### Why Not Infinite Retry?

A single poison message with infinite retry would:
1. Consume a retry slot every backoff cycle
2. Generate continuous WARNING logs
3. Never deliver, wasting broker connection resources
4. Create false confidence (the message appears "pending" but will never succeed)

Dead-lettering makes the failure explicit and actionable. Operators see it in `mqtt_pub.dead_letter_summary`, get a WARNING in the PostgreSQL log, and can choose to fix and replay, or discard.

## Configuration

| GUC | Default | Description |
|-----|---------|-------------|
| `pg_mqtt_pub.poison_max_attempts` | 5 | Delivery attempts before dead-lettering |
| `pg_mqtt_pub.outbox_batch_size` | 500 | Max rows drained per worker cycle |
| `pg_mqtt_pub.dead_letter_retain_days` | 30 | Auto-prune dead letters older than this |
| `pg_mqtt_pub.publish_timeout_ms` | 100 | Ring buffer backpressure (0 = spill to outbox immediately) |

## Consequences

### Benefits
- **Zero message loss** during broker outages (outbox is WAL-backed)
- **Sub-millisecond latency** during normal operation (ring buffer hot path)
- **Ordering preserved** across mode transitions (outbox drains before ring buffer resumes)
- **No trigger failures** — DML never fails because of MQTT (worst case: outbox INSERT adds ~2ms)
- **Crash recovery** — outbox rows survive Postgres restart; worker picks them up on startup
- **Observable** — `mqtt_status()` shows delivery_mode, `mqtt_pub.outbox_summary` shows queue depth

### Trade-offs
- **Cold path latency** — outbox INSERT adds ~2-5ms per trigger fire during outages (acceptable; triggers complete, data is safe)
- **Schema dependency** — extension creates tables in `mqtt_pub` schema (standard for PG extensions)
- **Ring buffer messages in-flight at mode switch** — if the worker pops a ring buffer message but publish fails, it spills that message to the outbox. Brief reordering possible within the same millisecond window; practically negligible.
- **Storage during extended outages** — outbox table grows unbounded during long outages. Monitor via `mqtt_pub.outbox_summary`. Consider adding a GUC for max outbox size in a future version.

### Not Addressed (Future Work)
- **Per-broker mode** — currently mode is global. A single disconnected broker forces all traffic to cold path. Per-broker routing would allow healthy brokers to stay on hot path.
- **Outbox size cap** — no maximum on outbox table size. Extended outages could grow it significantly.
- **Exactly-once delivery** — not guaranteed. QoS 2 provides exactly-once at the MQTT protocol level, but replay from dead letters could cause duplicates at the application level. Consumers should be idempotent.

## References

- [Transactional Outbox Pattern](https://microservices.io/patterns/data/transactional-outbox.html)
- [MQTT QoS Levels](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html)
- [PostgreSQL Background Workers](https://www.postgresql.org/docs/current/bgworker.html)
- [PostgreSQL Shared Memory](https://www.postgresql.org/docs/current/spi.html)
