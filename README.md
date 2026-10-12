# clickhouse-stack

A **learn-by-running** local stack showing:

- **ClickHouse** with **separation of storage and compute** — MergeTree data lives on object storage, not local disk.
- **MinIO** — a drop-in S3-compatible object server, used as the storage backend.
- **mc** — the MinIO client CLI, used as a one-shot init container to create the bucket + service account.
- **ClickStack (HyperDX)** — the observability UI + OTel collector on top of the same ClickHouse.

```
          OTLP (:4317/:4318)
  app ──▶  hyperdx-otel-collector ──┐
                                    ▼
                            ┌───────────────┐     S3 API      ┌──────────┐
                            │  ClickHouse   │ ───────────────▶│  MinIO  │
                            │   (compute)   │                 │ (storage)│
                            └───────┬───────┘                 └──────────┘
                                    │ HTTP :8123
                                    ▼
                                 hyperdx (UI :8080)
```

---

## Quickstart

```bash
docker compose up -d          # boot the whole stack
open http://localhost:8080    # one-time admin signup (any email/password)
./demo.sh                     # guided tour of every feature
```

That's it. Everything persists in Docker volumes; `docker compose down -v` for a clean reset.

### Endpoints

| Service          | URL                     | Credentials                |
|------------------|-------------------------|----------------------------|
| HyperDX UI       | http://localhost:8080   | (your signup)              |
| ClickHouse HTTP  | http://localhost:8123   | `default` / `clickhouse`   |
| MinIO console   | http://localhost:9001   | `minioadmin` / `minioadmin` |
| OTLP gRPC        | localhost:4317          | —                          |
| OTLP HTTP        | localhost:4318          | —                          |

---

## What's actually running

```
$ docker compose ps
NAME            IMAGE                                            STATUS
clickhouse      clickhouse/clickhouse-server:latest              Up (healthy)
minio           firstfinger/minio:latest                         Up (healthy)
minio-init      firstfinger/minio:latest                         Exited (0)      ← one-shot
hyperdx-otel    docker.hyperdx.io/.../hyperdx-otel-collector     Up (healthy)
hyperdx         hyperdx/hyperdx:latest                           Up (healthy)
hyperdx-mongo   mongo:9                                          Up
```

`minio-init` is deliberately a one-shot: it uses `mc` (bundled in the same image) to create the `clickhouse` bucket and a `clickhouse` service account, then exits. ClickHouse depends on it via `service_completed_successfully` so the first boot order is guaranteed.

---

## Tour: ClickHouse storage/compute separation

Run `./demo.sh ch`. Highlights:

### 1. ClickHouse knows about an S3-backed disk

```
▶ Which disks does ClickHouse know about?
┌─name──────┬─type──────────┬─path─────────────────────────────────┐
│ default   │ Local         │ /var/lib/clickhouse/                 │
│ s3_cache  │ ObjectStorage │ /var/lib/clickhouse/disks/s3_minio/ │
│ s3_minio │ ObjectStorage │ /var/lib/clickhouse/disks/s3_minio/ │
└───────────┴───────────────┴──────────────────────────────────────┘
```

`s3_minio` is the raw S3 disk pointed at `http://minio:9000/clickhouse/data/`. `s3_cache` wraps it with a 10 GiB local cache (`clickhouse/config.d/storage.xml`).

### 2. New MergeTree tables land on S3 by default

```
▶ Prove the parts actually sit on the S3 disk
┌─disk_name─┬─parts─┬─size─────┐
│ s3_cache  │     1 │ 8.10 MiB │
└───────────┴───────┴──────────┘
```

### 3. The bytes are really in MinIO

The script spins up a disposable `amazon/aws-cli` container and lists the bucket:

```
▶ List what MinIO has under the clickhouse/ bucket
2026-10-12 14:30:11    1.2 KiB data/vxu/rpqixnj...
2026-10-12 14:30:11    7.8 MiB data/aky/htknacu...
...
Total Objects: 42
   Total Size: 8.1 MiB
```

You can also open the MinIO console at <http://localhost:9001> and browse the `clickhouse` bucket.

### 4. Analytics still feel local, thanks to the cache

```
▶ Top actions by count
┌─action─┬──────c─┬─avg_amt─┐
│ view   │ 250000 │   21.47 │
│ click  │ 250000 │   21.46 │
│ buy    │ 250000 │   21.49 │
│ refund │ 250000 │   21.48 │
└────────┴────────┴─────────┘

▶ Query that just ran — look at the cache stats
┌─query_duration_ms─┬─read_rows─┬─read_bytes─┬─cache_hit_bytes─┐
│                38 │   1000000 │  8.00 MiB  │        8388608  │
└───────────────────┴───────────┴────────────┴─────────────────┘
```

The second number is bytes served from `s3_cache` instead of MinIO.

### 5. Incremental aggregation with a materialized view

```
▶ Read from the rollup (sumMerge finalizes the aggregate state)
┌──────────────minute─┬───total─┐
│ 2026-10-12 14:39:00 │ 2100000 │
└─────────────────────┴─────────┘
```

The MV updates on every `INSERT` into `demo.events`; the target table (`AggregatingMergeTree`) also sits on S3.

---

### 6. Cost tuning for object storage

Writing to object storage is pay-per-request, so turning 200 small `INSERT`s
into 200 S3 PUTs is the fast way to a surprise bill. Two defaults in this
stack address that:

**`async_insert` (set in `clickhouse/users.d/async_insert.xml`)** — the server
buffers tiny inserts and flushes one bigger part:

```
▶ Confirm async_insert is on for this session
┌─name─────────────────────────┬─value────┐
│ async_insert                 │ 1        │
│ wait_for_async_insert        │ 0        │
│ async_insert_max_data_size   │ 10485760 │
│ async_insert_busy_timeout_ms │ 2000     │
└──────────────────────────────┴──────────┘
```

**Compact + full-part-packed MergeTree** — raise
`min_bytes_for_wide_part` and `min_bytes_for_full_part_storage` so a part is
stored as one file instead of one-per-column:

```
▶ Fire 200 small INSERTs
▶ Row count + part count
┌─part_type─┬─parts─┬─size──────┐
│ Compact   │     2 │ 24.88 KiB │
└───────────┴───────┴───────────┘
```

200 inserts → **2 parts**. Without `async_insert` this would be 200 parts and
~200 S3 PUTs just for this one table.

Background merges then keep collapsing parts into bigger ones over time, so
the object count drifts *down* as data ages instead of up.

**Bonus: the `s3_packed` policy.** A second disk (`s3_minio_packed`) in
`storage.xml` uses the newer `plain_rewritable` object-storage metadata type,
which stores part metadata directly in the bucket (no local sidecar file per
part). Create a table with `SETTINGS storage_policy='s3_packed'` and you get
a dramatic reduction in S3 object count:

```
▶ Actual S3 objects on MinIO per prefix
   default (s3_main):
     Total Objects: 5035
        Total Size: 37245757
   packed (s3_packed):
     Total Objects:  490
        Total Size:  2155800
```

~10× fewer S3 PUTs for the exact same workload. Note: `plain_rewritable`
requires a backend that honors specific S3 list/write semantics; MinIO
supports it, but not every S3-compatible server does (we initially tried
RustFS and the disk failed to initialize).

---

## Tour: ClickStack (HyperDX) telemetry

Run `./demo.sh otel`. The script sends OTLP/HTTP straight to the collector and reads it back out of ClickHouse.

### Send & read logs

```
▶ POST a few logs to the collector at http://localhost:4318/v1/logs
   {"partialSuccess":{}}

▶ Verify in ClickHouse
┌─SeverityText─┬─ServiceName─┬─Body───────────────────────────┐
│ ERROR        │ demo-shop   │ payment gateway timeout        │
│ WARN         │ demo-shop   │ inventory low for sku_7        │
│ INFO         │ demo-shop   │ checkout started for user_42   │
└──────────────┴─────────────┴────────────────────────────────┘
```

### Send & read a distributed trace

```
▶ Verify in ClickHouse
┌─ServiceName─┬─SpanName─┬─SpanKind─┬─duration_ms─┐
│ demo-shop   │ charge   │ Client   │         120 │
│ demo-shop   │ checkout │ Server   │         120 │
└─────────────┴──────────┴──────────┴─────────────┘
```

The script prints the TraceId; paste it into HyperDX → Search (source: **Traces**) to see the waterfall.

### Send & read a gauge metric

```
▶ Verify in ClickHouse
┌─MetricName──────┬──Value─┬─Attributes───────────┐
│ shop.cart.value │ 123.45 │ {'region':'us-east'} │
└─────────────────┴────────┴──────────────────────┘
```

### Explore in the UI

Open <http://localhost:8080> and poke at:

- **Search** → pick Logs / Traces / Metrics, filter by `service.name = demo-shop`.
- **Service Map** → `demo-shop` appears once a few spans flow.
- **Dashboards** → charts built off the preseeded sources.
- **Chart Explorer** → ad-hoc SQL over ClickHouse.

The connection and the Logs/Traces/Metrics sources are preseeded via `DEFAULT_CONNECTIONS` and `DEFAULT_SOURCES` in `docker-compose.yml`, so once you've signed up, there's no manual wiring.

---

## Pointing your own app at the stack

Any OpenTelemetry SDK — set the exporter to the collector:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318      # HTTP
# or
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317      # gRPC
export OTEL_SERVICE_NAME=my-app
```

Your spans/logs/metrics appear in HyperDX within a few seconds.

---

## Repo layout

```
.
├── docker-compose.yml                  # the stack
├── clickhouse/
│   ├── config.d/
│   │   ├── storage.xml                 # S3 disk + cache + default policy
│   │   └── listen.xml                  # bind to 0.0.0.0 (else container-local only)
│   └── users.d/
│       └── async_insert.xml            # cost-tuning: coalesce small INSERTs
├── demo.sh                             # the guided tour
└── README.md
```

---

## Resets & gotchas

- **Full reset:** `docker compose down -v` (wipes MinIO data, ClickHouse data, Mongo state).
- **Reseed HyperDX sources only** (e.g. after editing `DEFAULT_SOURCES`):
  ```bash
  docker exec hyperdx-mongo mongosh hyperdx --quiet \
    --eval 'db.sources.drop(); db.connections.drop()'
  docker compose restart hyperdx
  ```
- **ClickHouse must bind to `0.0.0.0`** inside the container (`clickhouse/config.d/listen.xml`). Without it, the healthcheck passes on `localhost` but other services get `connection refused`.
- **HyperDX requires a one-time admin signup** on first boot — the multi-user `hyperdx/hyperdx` image has no "skip auth" env. The account is persisted in the `mongo-data` volume, so subsequent `up`s are instant.
- **`clickhouse-server:latest` moves.** If a release renames an S3 disk setting, pin a tag (e.g. `:24.8` or `:25.3`) in `docker-compose.yml`.

---

## Why this stack?

- **Compute scales independently of storage.** Blow away the ClickHouse container, keep the MinIO volume, start a new ClickHouse pointing at the same bucket — your data is still there.
- **MinIO is API-compatible with S3**, so this topology maps 1:1 to a production setup against AWS S3, GCS (via S3 interop), or self-hosted MinIO — just change the endpoint.
- **ClickStack reuses the same ClickHouse** as your analytical workload, instead of standing up a separate Elasticsearch/Loki/Prometheus for observability.
