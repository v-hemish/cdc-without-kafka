# CDC Without Kafka

**What happens to a PostgreSQL CDC pipeline when Kafka is removed?**

This project runs PostgreSQL → Debezium → Apache Iceberg directly, then deliberately stops the CDC consumer to observe where the backlog accumulates.

![CDC without Kafka experiment](./img.png)

## The Question

A common CDC architecture looks like:

```text
PostgreSQL
    ↓
Debezium
    ↓
Kafka
    ↓
Iceberg
```

Kafka gives the pipeline a durable intermediate log for buffering, replay, fan-out, and failure isolation.

But what if the requirement is much simpler?

```text
one PostgreSQL database
        ↓
one lakehouse
```

Can we remove Kafka?

And if we do:

**Where does the backlog go when the CDC consumer fails?**

## Architecture

This lab runs:

```text
PostgreSQL
    ↓
WAL
    ↓
Logical Replication Slot
    ↓
Debezium Server
    ↓
Apache Iceberg
    ↓
MinIO
```

DuckDB is used to validate the resulting Iceberg table.

**No Kafka is involved.**

## How It Works

PostgreSQL records database changes in its Write-Ahead Log (WAL).

Debezium connects through PostgreSQL logical replication and converts those changes into CDC events.

The replication slot tracks how far Debezium has consumed the WAL.

When Debezium is healthy:

```text
Postgres → WAL → replication slot → Debezium → Iceberg
```

The replication position keeps advancing.

When Debezium stops:

```text
Postgres → WAL → replication slot → X
```

PostgreSQL must retain WAL that the consumer has not yet processed.

That behavior is the focus of this experiment.

## Stack

* PostgreSQL 17
* Debezium Server
* Apache Iceberg
* MinIO
* DuckDB
* Docker Compose

## Start the Lab

```bash
docker compose up -d
```

Check the services:

```bash
docker compose ps
```

Inspect the PostgreSQL replication slot:

```bash
docker exec -it cdc-postgres \
  psql -U postgres -d cdc_lab \
  -c "
SELECT
    slot_name,
    active,
    pg_size_pretty(
        pg_wal_lsn_diff(
            pg_current_wal_lsn(),
            restart_lsn
        )
    ) AS retained_wal,
    restart_lsn,
    confirmed_flush_lsn
FROM pg_replication_slots;
"
```

During normal operation, the slot should be active because Debezium is consuming the WAL.

## Experiment

### 1. Healthy CDC

With Debezium running:

```text
Replication slot: active
Retained WAL:     ~1.28 KB
```

### 2. Stop Debezium

```bash
docker stop cdc-debezium
```

Now the replication slot becomes inactive.

### 3. Generate 100,000 PostgreSQL Changes

```bash
docker exec -it cdc-postgres \
  psql -U postgres -d cdc_lab \
  -c "
INSERT INTO customers (name, plan)
SELECT
    'user_' || g,
    CASE
        WHEN g % 3 = 0 THEN 'enterprise'
        WHEN g % 2 = 0 THEN 'pro'
        ELSE 'free'
    END
FROM generate_series(1, 100000) AS g;
"
```

Inspect the replication slot again.

Observed:

```text
Replication slot: inactive
Retained WAL:     ~15 MB
```

The backlog did not disappear.

It accumulated as PostgreSQL WAL retained for the replication slot.

### 4. Restart Debezium

```bash
docker start cdc-debezium
```

Debezium begins consuming the backlog again.

The Iceberg sink processed the accumulated changes in batches of approximately:

```text
2048 events
2048 events
2048 events
...
1696 events
```

### 5. Validate the Result

PostgreSQL:

```text
100,003 rows
```

Iceberg:

```text
100,003 rows
```

The destination successfully caught up.

## Results

| State                            | Retained WAL |
| -------------------------------- | -----------: |
| Healthy CDC                      |      1.28 KB |
| Debezium stopped + 100k new rows |        15 MB |

The key observation:

> **Removing Kafka did not remove the queue. It changed where the pressure lived.**

With Kafka:

```text
Postgres
   ↓
Debezium
   ↓
Kafka █████ backlog
   ↓
Iceberg
```

Without Kafka:

```text
Postgres
   ↓
WAL █████ backlog
   ↓
Debezium
   ↓
Iceberg
```

When the CDC consumer cannot progress, PostgreSQL retains WAL required by the replication slot.

## What This Means

A direct CDC pipeline can be attractive when the architecture is simple:

```text
one source
    ↓
one destination
```

It reduces infrastructure and operational complexity.

Kafka becomes much more valuable when you need:

* long-lived replay
* multiple independent consumers
* durable buffering away from the source database
* isolation from slow downstream systems
* high or unpredictable change volume
* event-driven architectures beyond a single destination

The point of this experiment is **not**:

> Kafka is unnecessary.

The point is:

> **Understand what Kafka is giving you before adding it to the architecture.**

## Repository Structure

```text
cdc-without-kafka/
├── docker-compose.yml
├── img.png
├── postgres/
│   └── init.sql
├── debezium/
│   └── application.properties
├── scripts/
├── results/
└── README.md
```

## Stop the Lab

```bash
docker compose down
```

This preserves the PostgreSQL and MinIO volumes.

To completely remove the stored data as well:

```bash
docker compose down -v
```

## Main Takeaway

**Removing Kafka didn't remove the queue. PostgreSQL WAL became the backlog.**

This project is a small systems experiment designed to understand CDC failure behavior rather than just configure the tools.
