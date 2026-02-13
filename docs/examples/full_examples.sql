-- ═══════════════════════════════════════════════════════════════
--  pg_mqtt_pub Examples — Hybrid Delivery Model
-- ═══════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_mqtt_pub;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ───────────────────────────────────
-- 1. Verify delivery mode
-- ───────────────────────────────────

SELECT * FROM mqtt_pub.mqtt_status();
-- delivery_mode = 'hot' when brokers healthy
-- delivery_mode = 'cold' when broker(s) down

-- ───────────────────────────────────
-- 2. Event-based trigger setup (one message per row)
-- ───────────────────────────────────

CREATE TABLE sensor_readings (
    id          serial PRIMARY KEY,
    sensor_id   text NOT NULL,
    value       double precision NOT NULL,
    unit        text DEFAULT 'celsius',
    location    text,
    recorded_at timestamptz DEFAULT now()
);

SELECT mqtt_pub.mqtt_trigger_event_setup('sensor_readings');

INSERT INTO sensor_readings (sensor_id, value, location)
VALUES ('temp-001', 23.5, 'server-room-a');
-- HOT mode: enqueued to ring buffer in ~0.1ms
-- COLD mode: inserted into mqtt_pub.outbox in ~2ms
-- Either way, the INSERT succeeds.

-- ───────────────────────────────────
-- 2b. Resultset trigger for batch operations (one message per statement)
-- ───────────────────────────────────

CREATE TABLE inventory_items (
    id          serial PRIMARY KEY,
    sku         text UNIQUE NOT NULL,
    quantity    integer NOT NULL DEFAULT 0,
    updated_at  timestamptz DEFAULT now()
);

-- Track batch inventory updates as single messages
SELECT mqtt_pub.mqtt_trigger_resultset_setup(
    'inventory_items',
    'sync/inventory/batch',
    '{UPDATE}',
    2
);

-- Batch update publishes ONE message with all affected rows
UPDATE inventory_items SET quantity = quantity - 1
WHERE sku IN ('ITEM001', 'ITEM002', 'ITEM003', 'ITEM004');
-- Publishes single message: {"_count": 4, "data": [{old: {...}, new: {...}}, ...]}

-- ───────────────────────────────────
-- 3. Threshold alert with QoS 2
-- ───────────────────────────────────

CREATE OR REPLACE FUNCTION alert_high_temperature()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.value > 40.0 THEN
        PERFORM mqtt_pub.mqtt_publish(
            format('alerts/temperature/%s', NEW.sensor_id),
            json_build_object(
                'sensor_id', NEW.sensor_id,
                'value',     NEW.value,
                'severity',  CASE
                    WHEN NEW.value > 60 THEN 'critical'
                    WHEN NEW.value > 50 THEN 'warning'
                    ELSE 'info'
                END,
                'location',  NEW.location,
                'timestamp', NEW.recorded_at
            )::text,
            2,
            true
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER sensor_alert
    AFTER INSERT ON sensor_readings
    FOR EACH ROW EXECUTE FUNCTION alert_high_temperature();

-- ───────────────────────────────────
-- 4. pg_cron: periodic analytics
-- ───────────────────────────────────

SELECT cron.schedule('mqtt-hourly-stats', '0 * * * *', $$
    SELECT mqtt_pub.mqtt_publish(
        'analytics/temperature/hourly',
        (
            SELECT json_build_object(
                'period_start', date_trunc('hour', now() - interval '1 hour'),
                'period_end',   date_trunc('hour', now()),
                'sensors', json_agg(json_build_object(
                    'sensor_id', sensor_id,
                    'avg', round(avg_val::numeric, 2),
                    'min', min_val, 'max', max_val, 'count', cnt
                ))
            )::text
            FROM (
                SELECT sensor_id, avg(value) avg_val, min(value) min_val,
                       max(value) max_val, count(*) cnt
                FROM sensor_readings
                WHERE recorded_at >= date_trunc('hour', now() - interval '1 hour')
                  AND recorded_at <  date_trunc('hour', now())
                GROUP BY sensor_id
            ) agg
        ),
        1, true
    );
$$);

-- ───────────────────────────────────
-- 5. pg_cron: batch sync with outbox awareness
-- ───────────────────────────────────

CREATE TABLE orders (
    id             serial PRIMARY KEY,
    customer_id    integer NOT NULL,
    total          numeric(10,2),
    status         text DEFAULT 'pending',
    created_at     timestamptz DEFAULT now(),
    mqtt_synced    boolean DEFAULT false,
    mqtt_synced_at timestamptz
);

SELECT cron.schedule('mqtt-sync-orders', '*/5 * * * *', $$
    WITH batch AS (
        SELECT id, row_to_json(o)::text as payload
        FROM orders o
        WHERE NOT mqtt_synced
        ORDER BY created_at
        LIMIT 500
        FOR UPDATE SKIP LOCKED
    ),
    sent AS (
        SELECT b.id,
               mqtt_pub.mqtt_publish(
                   'erp/orders/' || b.id,
                   b.payload,
                   2
               ) as ok
        FROM batch b
    )
    UPDATE orders SET mqtt_synced = true, mqtt_synced_at = now()
    WHERE id IN (SELECT id FROM sent WHERE ok);
$$);

-- ───────────────────────────────────
-- 6. Multi-broker routing
-- ───────────────────────────────────

SELECT mqtt_pub.mqtt_broker_add(
    'cloud', 'mqtt.analytics.com',
    8883, NULL::text, NULL::text, true, '/etc/ssl/ca.pem'
);

SELECT mqtt_pub.mqtt_broker_add(
    'edge', '192.168.1.100', 1883
);

CREATE OR REPLACE FUNCTION route_sensor_data()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Local edge broker (low latency, fire-and-forget)
    PERFORM mqtt_pub.mqtt_publish(
        'devices/' || NEW.sensor_id || '/reading',
        json_build_object('value', NEW.value, 'ts', NEW.recorded_at)::text,
        0,
        false,
        'edge'
    );

    -- Cloud broker (durable, higher QoS)
    PERFORM mqtt_pub.mqtt_publish(
        'ingest/sensors/' || NEW.sensor_id,
        row_to_json(NEW)::text,
        1,
        false,
        'cloud'
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER sensor_multi_route
    AFTER INSERT ON sensor_readings
    FOR EACH ROW EXECUTE FUNCTION route_sensor_data();

-- ───────────────────────────────────
-- 7. Monitor the hybrid system
-- ───────────────────────────────────

-- Dashboard query
SELECT
    broker_name, connected, delivery_mode,
    messages_sent, messages_failed,
    dead_lettered, outbox_pending, last_error
FROM mqtt_pub.mqtt_status();

-- Outbox health
SELECT * FROM mqtt_pub.outbox_summary;

-- Dead letter investigation
SELECT id, topic, attempts, last_error, dead_lettered_at
FROM mqtt_pub.dead_letters
ORDER BY dead_lettered_at DESC
LIMIT 20;

-- Replay dead letters back to outbox
SELECT mqtt_pub.replay_dead_letters('default', 50);

-- ───────────────────────────────────
-- 8. pg_cron: self-monitoring
-- ───────────────────────────────────

SELECT cron.schedule('mqtt-health-check', '* * * * *', $cron$
    DO $code$
    DECLARE
        r record;
    BEGIN
        FOR r IN SELECT * FROM mqtt_pub.mqtt_status() LOOP
            IF NOT r.connected THEN
                RAISE WARNING 'pg_mqtt_pub: broker "%" disconnected (mode=%, pending=%)',
                    r.broker_name, r.delivery_mode, r.outbox_pending;
            END IF;
            IF r.dead_lettered > 0 THEN
                RAISE WARNING 'pg_mqtt_pub: % dead-lettered messages for broker "%"',
                    r.dead_lettered, r.broker_name;
            END IF;
        END LOOP;
    END $code$;
$cron$);
