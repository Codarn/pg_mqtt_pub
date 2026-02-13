# pg_mqtt_pub — PostgreSQL MQTT Publish Extension

A PostgreSQL extension that publishes MQTT messages directly from SQL, triggers, and `pg_cron` jobs. Uses a **hybrid delivery model** with automatic failover between a high-speed shared memory ring buffer and a WAL-durable outbox table, ensuring zero message loss during broker outages without sacrificing trigger performance.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                        PostgreSQL                               │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  pg_trigger   │  │   pg_cron    │  │  SELECT mqtt_publish │  │
│  │  AFTER INSERT │  │  */5 * * * * │  │  (topic, payload)    │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘  │
│         └──────────────────┼────────────────────┘              │
│                            ▼                                    │
│                  ┌───────────────────┐                          │
│                  │  Hybrid Router     │                          │
│                  │  mqtt_publish()    │                          │
│                  └─────────┬─────────┘                          │
│                            │                                    │
│              ┌─── HOT ─────┼────── COLD ───┐                   │
│              ▼             │                ▼                   │
│   ┌──────────────────┐    │     ┌────────────────────────┐     │
│   │  Ring Buffer      │    │     │  mqtt_pub.outbox        │     │
│   │  (shared memory)  │    │     │  (WAL-backed table)     │     │
│   │  ~0.1ms latency   │    │     │  ~2-5ms latency         │     │
│   │  volatile          │    │     │  crash-safe             │     │
│   └────────┬─────────┘    │     └──────────┬─────────────┘     │
│            └───────────────┼────────────────┘                   │
│                            ▼                                    │
│              ┌──────────────────────────┐                       │
│              │  Background Worker        │                       │
│              │  Priority:                │                       │
│              │   1. drain outbox (FIFO)  │                       │
│              │   2. drain ring buffer    │                       │
│              │                           │                       │
│              │  On publish failure:      │                       │
│              │   → retry w/ backoff      │                       │
│              │   → dead-letter at max    │                       │
│              └────────────┬─────────────┘                       │
│                           │                                     │
└───────────────────────────┼─────────────────────────────────────┘
                            │
                            ▼
                  ┌──────────────────┐
                  │   MQTT Broker    │
                  │   (mosquitto,    │
                  │    HiveMQ, etc.) │
                  └──────────────────┘
```

### Delivery Modes

The extension operates in one of two modes, switching automatically:

**HOT mode** (normal operation) — SQL functions enqueue messages into a lock-free shared memory ring buffer. The background worker pops and publishes with sub-millisecond latency. No disk I/O, no WAL writes. This is the fast path that keeps triggers fast.

**COLD mode** (broker outage) — When a broker disconnects, the worker flips a shared memory flag. All subsequent `mqtt_publish()` calls write to the `mqtt_pub.outbox` table instead. These rows are WAL-protected and survive Postgres crashes. When the broker reconnects, the worker drains the outbox in FIFO order, then switches back to HOT.

The outbox is fully drained before switching back to HOT, which preserves message ordering across mode transitions.

### Poison Message Guardrails

Messages that repeatedly fail to publish (malformed topics, ACL rejections, oversized payloads) are handled with exponential backoff and eventual dead-lettering:

```
Attempt 1: fail → retry in 1s
Attempt 2: fail → retry in 2s
Attempt 3: fail → retry in 4s
Attempt 4: fail → retry in 8s
Attempt 5: fail → moved to mqtt_pub.dead_letters
```

Poison messages are time-displaced (via `next_retry_at`) rather than queue-blocking, so they don't hold up healthy messages behind them. Dead letters are retained for investigation and can be replayed with `mqtt_pub.replay_dead_letters()`.

## Building

### Dependencies

```bash
# Ubuntu/Debian
sudo apt install postgresql-server-dev-17 libmosquitto-dev

# RHEL/Fedora
sudo dnf install postgresql17-devel mosquitto-devel

# Arch
sudo pacman -S postgresql-libs mosquitto
```

### Compile & Install

```bash
make
sudo make install
```

### Enable

```ini
# postgresql.conf
shared_preload_libraries = 'pg_mqtt_pub'
```

```sql
CREATE EXTENSION pg_mqtt_pub;
```

## Configuration (postgresql.conf)

```ini
# ── Broker Connection ──
pg_mqtt_pub.broker_host = 'localhost'
pg_mqtt_pub.broker_port = 1883
pg_mqtt_pub.broker_username = ''
pg_mqtt_pub.broker_password = ''
pg_mqtt_pub.broker_use_tls = false
pg_mqtt_pub.broker_ca_cert = ''

# ── Performance ──
pg_mqtt_pub.queue_size = 65536              # Ring buffer slots (power of 2)
pg_mqtt_pub.reconnect_interval_ms = 5000    # Base reconnect backoff
pg_mqtt_pub.publish_timeout_ms = 100        # Wait when ring buffer full (0 = spill to outbox)
pg_mqtt_pub.worker_poll_interval_ms = 10    # Background worker poll interval

# ── Poison Message / Dead Letter ──
pg_mqtt_pub.poison_max_attempts = 5         # Max delivery attempts before dead-lettering
pg_mqtt_pub.outbox_batch_size = 500         # Max outbox rows drained per cycle
pg_mqtt_pub.dead_letter_retain_days = 30    # Auto-prune dead letters after this many days
```

## SQL API

### Publishing

```sql
-- Text payload
SELECT mqtt_publish(
    topic   := 'sensors/temp/room1',
    payload := '{"value": 23.5}',
    qos     := 1,
    retain  := false,
    broker  := 'default'
);

-- JSON (auto-serialized)
SELECT mqtt_publish_json(
    topic := 'db/events/users',
    data  := row_to_json(NEW),
    qos   := 1
);

-- Batch
SELECT mqtt_publish_batch(
    topic_prefix := 'sync/orders',
    payloads     := ARRAY(SELECT row_to_json(o)::text FROM orders o WHERE NOT synced),
    qos          := 2
);
```

### Broker Management

```sql
SELECT mqtt_broker_add(
    name := 'cloud', host := 'mqtt.example.com',
    port := 8883, use_tls := true, ca_cert := '/etc/ssl/ca.pem'
);

SELECT mqtt_broker_remove('cloud');
```

### Monitoring

```sql
-- Per-broker status with delivery mode
SELECT * FROM mqtt_status();
--  broker_name | host      | port | connected | delivery_mode | messages_sent | messages_failed | dead_lettered | outbox_pending | last_error
-- -------------+-----------+------+-----------+---------------+---------------+-----------------+---------------+----------------+-----------
--  default     | localhost | 1883 | true      | hot           |         12847 |               3 |             1 |              0 | ∅

-- Outbox depth per broker
SELECT * FROM mqtt_pub.outbox_summary;

-- Dead letter diagnostics
SELECT * FROM mqtt_pub.dead_letter_summary;

-- Replay failed messages
SELECT mqtt_pub.replay_dead_letters('default', 50);
```

### Trigger Setup Helpers

#### Event-based triggers (one message per row)

```sql
-- Publishes individual row changes to db/changes/sensor_readings/{insert|update|delete}
SELECT mqtt_trigger_event_setup('sensor_readings');

-- Custom topic and QoS
SELECT mqtt_trigger_event_setup(
    table_name   := 'orders',
    topic_prefix := 'erp/orders/events',
    operations   := '{INSERT,UPDATE}',
    qos          := 2
);
```

#### Resultset-based triggers (one message per statement)

```sql
-- Publishes all affected rows in a single message (ideal for batch operations)
SELECT mqtt_trigger_resultset_setup('orders');

-- Example: UPDATE orders SET status = 'shipped' WHERE condition
-- Publishes once with all updated rows: {"data": [{old: {...}, new: {...}}, ...]}

-- Use case: Batch synchronization
SELECT mqtt_trigger_resultset_setup(
    table_name   := 'inventory_items',
    topic_prefix := 'sync/inventory/batch',
    operations   := '{UPDATE}',  -- Only track batch updates
    qos          := 2
);
```

**When to use each trigger type:**
- **Event triggers** (`mqtt_trigger_event_setup`): Real-time event streaming, immediate notifications, row-level CDC
- **Resultset triggers** (`mqtt_trigger_resultset_setup`): Batch operations, bulk sync, aggregated change notifications

### Custom Trigger with Filtering

```sql
CREATE FUNCTION alert_on_high_temp() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.value > 40.0 THEN
        PERFORM mqtt_publish(
            topic   := format('alerts/temp/%s', NEW.sensor_id),
            payload := json_build_object(
                'sensor_id', NEW.sensor_id,
                'value', NEW.value,
                'severity', CASE WHEN NEW.value > 60 THEN 'critical' ELSE 'warning' END
            )::text,
            qos := 2, retain := true
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER temp_alert AFTER INSERT ON sensor_readings
    FOR EACH ROW EXECUTE FUNCTION alert_on_high_temp();
```

### pg_cron Integration

```sql
-- Hourly aggregation
SELECT cron.schedule('mqtt-hourly-stats', '0 * * * *', $$
    SELECT mqtt_publish(
        topic := 'analytics/temperature/hourly',
        payload := (SELECT json_build_object(
            'hour', date_trunc('hour', now() - interval '1 hour'),
            'avg',  round(avg(value)::numeric, 2),
            'count', count(*)
        )::text FROM sensor_readings
        WHERE recorded_at >= date_trunc('hour', now() - interval '1 hour')),
        qos := 1, retain := true
    );
$$);

-- Health heartbeat every 30s
SELECT cron.schedule('mqtt-heartbeat', '*/30 * * * * *', $$
    SELECT mqtt_publish(
        topic := 'monitoring/postgres/heartbeat',
        payload := json_build_object(
            'timestamp', now(),
            'active_conns', (SELECT count(*) FROM pg_stat_activity WHERE state = 'active'),
            'db_size_mb', pg_database_size(current_database()) / 1048576
        )::text,
        qos := 0, retain := true
    );
$$);
```

## Schema

The extension creates the `mqtt_pub` schema containing:

| Object | Type | Purpose |
|--------|------|---------|
| `mqtt_pub.outbox` | table | WAL-durable message queue (cold path) |
| `mqtt_pub.dead_letters` | table | Messages that exceeded max delivery attempts |
| `mqtt_pub.outbox_summary` | view | Aggregate outbox state per broker |
| `mqtt_pub.dead_letter_summary` | view | Dead letter diagnostics per broker |
| `mqtt_pub.replay_dead_letters()` | function | Move dead letters back to outbox for retry |

## Docker Quick Start

```bash
docker compose up -d

# Watch MQTT messages in real-time
docker compose logs -f mqtt-monitor

# Connect to Postgres
docker compose exec postgres psql -U postgres -d testdb

# Try it
CREATE EXTENSION pg_mqtt_pub;
SELECT mqtt_publish('test/hello', 'world');
SELECT * FROM mqtt_status();
```

## Architecture Decision Records

Design decisions are documented in [`docs/adr/`](docs/adr/):

- [ADR-001: Hybrid Delivery Model](docs/adr/001-hybrid-delivery-model.md) — Hot/cold path design, poison message guardrails, mode transition logic

## License

PostgreSQL License (same as PostgreSQL itself).
