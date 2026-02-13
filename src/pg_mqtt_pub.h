/*
 * pg_mqtt_pub.h — PostgreSQL MQTT Publish Extension
 *
 * Shared definitions for the hybrid delivery model:
 *   - Hot path:  shared memory ring buffer (sub-ms, volatile)
 *   - Cold path: WAL-backed outbox table (durable, higher latency)
 *
 * The background worker drains the outbox first (FIFO), then the ring buffer,
 * preserving message ordering during failover/recovery.
 *
 * Copyright (c) 2025, PostgreSQL License
 */

#ifndef PG_MQTT_PUB_H
#define PG_MQTT_PUB_H

#include "postgres.h"
#include "fmgr.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/timestamp.h"

/* ───────── Constants ───────── */

#define PGMQTTPUB_MAGIC               0x4D51  /* "MQ" */
#define PGMQTTPUB_MAX_BROKERS         8
#define PGMQTTPUB_MAX_TOPIC_LEN       1024
#define PGMQTTPUB_MAX_PAYLOAD_LEN     (256 * 1024)
#define PGMQTTPUB_MAX_BROKER_NAME     32
#define PGMQTTPUB_MAX_HOST_LEN        256
#define PGMQTTPUB_MAX_CRED_LEN        256
#define PGMQTTPUB_MAX_PATH_LEN        1024
#define PGMQTTPUB_DEFAULT_QUEUE_SIZE  65536
#define PGMQTTPUB_SLOT_SIZE           2048
#define PGMQTTPUB_DEFAULT_BROKER_NAME "default"

/* ───────── Poison Message Guardrails ───────── */

#define PGMQTTPUB_POISON_MAX_ATTEMPTS_DEFAULT     5
#define PGMQTTPUB_POISON_BACKOFF_BASE_MS          1000
#define PGMQTTPUB_POISON_BACKOFF_CAP_MS           30000

/* ───────── Outbox Drain Tuning ───────── */

#define PGMQTTPUB_OUTBOX_BATCH_SIZE_DEFAULT       500
#define PGMQTTPUB_OUTBOX_POLL_INTERVAL_MS         100
#define PGMQTTPUB_DEAD_LETTER_RETAIN_DAYS_DEFAULT 30

/* ───────── Message Flags ───────── */

#define PGMQTTPUB_FLAG_QOS_MASK    0x03
#define PGMQTTPUB_FLAG_RETAIN      0x04

/* ───────── Delivery Mode ───────── */

typedef enum PgMqttPubDeliveryMode
{
    PGMQTTPUB_MODE_HOT  = 0,   /* ring buffer — all brokers healthy */
    PGMQTTPUB_MODE_COLD = 1    /* outbox table — broker(s) down     */
} PgMqttPubDeliveryMode;

/* ───────── Broker Connection State ───────── */

typedef enum PgMqttPubConnState
{
    PGMQTTPUB_CONN_DISCONNECTED = 0,
    PGMQTTPUB_CONN_CONNECTING,
    PGMQTTPUB_CONN_CONNECTED,
    PGMQTTPUB_CONN_ERROR
} PgMqttPubConnState;

/* ───────── Broker Configuration (in shared memory) ───────── */

typedef struct PgMqttPubBrokerConfig
{
    char        name[PGMQTTPUB_MAX_BROKER_NAME];
    char        host[PGMQTTPUB_MAX_HOST_LEN];
    int         port;
    char        username[PGMQTTPUB_MAX_CRED_LEN];
    char        password[PGMQTTPUB_MAX_CRED_LEN];
    bool        use_tls;
    char        ca_cert_path[PGMQTTPUB_MAX_PATH_LEN];
    char        client_cert_path[PGMQTTPUB_MAX_PATH_LEN];
    char        client_key_path[PGMQTTPUB_MAX_PATH_LEN];
    bool        active;
} PgMqttPubBrokerConfig;

/* ───────── Broker Runtime State (in shared memory) ───────── */

typedef struct PgMqttPubBrokerState
{
    PgMqttPubConnState  state;
    uint64              messages_sent;
    uint64              messages_failed;
    uint64              messages_dead_lettered;
    uint32              queue_depth;
    TimestampTz         connected_since;
    TimestampTz         disconnected_since;
    char                last_error[256];
} PgMqttPubBrokerState;

/* ───────── Ring Buffer Message Slot ───────── */

typedef struct PgMqttPubMessage
{
    uint16  magic;
    uint8   flags;
    char    broker_name[PGMQTTPUB_MAX_BROKER_NAME];
    uint16  topic_len;
    uint32  payload_len;
    char    data[PGMQTTPUB_SLOT_SIZE - sizeof(uint16) - sizeof(uint8)
                 - PGMQTTPUB_MAX_BROKER_NAME - sizeof(uint16) - sizeof(uint32)];
} PgMqttPubMessage;

/* ───────── Shared Memory Ring Buffer ───────── */

typedef struct PgMqttPubQueue
{
    LWLock     *lock;
    pg_atomic_uint32 head;
    pg_atomic_uint32 tail;
    uint32      capacity;
} PgMqttPubQueue;

/* ───────── Top-Level Shared Memory State ───────── */

typedef struct PgMqttPubSharedState
{
    LWLock                     *config_lock;
    PgMqttPubBrokerConfig       brokers[PGMQTTPUB_MAX_BROKERS];
    PgMqttPubBrokerState        broker_states[PGMQTTPUB_MAX_BROKERS];
    PgMqttPubQueue              queue;
    bool                        worker_running;
    pid_t                       worker_pid;

    /* ── Hybrid Delivery State ── */
    pg_atomic_uint32            delivery_mode;       /* PgMqttPubDeliveryMode */
    pg_atomic_uint64            outbox_pending;      /* approx outbox row count */
    pg_atomic_uint64            total_dead_lettered; /* lifetime dead letter count */
    TimestampTz                 mode_changed_at;     /* last hot↔cold switch */
} PgMqttPubSharedState;

/* ───────── Global Shared State Pointer ───────── */

extern PgMqttPubSharedState *pgmqttpub_shared;

/* ───────── GUC Variables ───────── */

extern char *pgmqttpub_broker_host;
extern int   pgmqttpub_broker_port;
extern char *pgmqttpub_broker_username;
extern char *pgmqttpub_broker_password;
extern bool  pgmqttpub_broker_use_tls;
extern char *pgmqttpub_broker_ca_cert;
extern char *pgmqttpub_broker_client_cert;
extern char *pgmqttpub_broker_client_key;
extern int   pgmqttpub_queue_size;
extern int   pgmqttpub_max_connections;
extern int   pgmqttpub_reconnect_interval_ms;
extern int   pgmqttpub_publish_timeout_ms;
extern int   pgmqttpub_worker_poll_interval_ms;
extern int   pgmqttpub_poison_max_attempts;
extern int   pgmqttpub_outbox_batch_size;
extern int   pgmqttpub_dead_letter_retain_days;

/* ───────── Queue Operations (hot path) ───────── */

bool pgmqttpub_queue_push(const char *broker_name, const char *topic,
                          const char *payload, int payload_len,
                          int qos, bool retain);
bool pgmqttpub_queue_pop(PgMqttPubMessage *msg);

/* ───────── Outbox Operations (cold path) ───────── */

bool pgmqttpub_outbox_insert(const char *broker_name, const char *topic,
                             const char *payload, int payload_len,
                             int qos, bool retain);

/* ───────── Routing: hot vs cold path ───────── */

bool pgmqttpub_route_message(const char *broker_name, const char *topic,
                             const char *payload, int payload_len,
                             int qos, bool retain);

/* ───────── Broker Helpers ───────── */

int  pgmqttpub_find_broker(const char *name);
int  pgmqttpub_add_broker(PgMqttPubBrokerConfig *config);
bool pgmqttpub_remove_broker(const char *name);

/* ───────── Background Worker Entry Point ───────── */

PGDLLEXPORT void pgmqttpub_worker_main(Datum main_arg);

#endif /* PG_MQTT_PUB_H */
