# clickhouse-stack

A **learn-by-running** local stack showing:

- **ClickHouse** with **separation of storage and compute** — MergeTree data lives on object storage, not local disk.
- **RustFS** — a Rust S3-compatible server, used as the object store (MinIO-shaped API).
- **rustfs/rc** — the RustFS CLI, used as a one-shot init container to create the bucket + service account.
- **ClickStack (HyperDX)** — the observability UI + OTel collector on top of the same ClickHouse.

```
          OTLP (:4317/:4318)
  app ──▶  hyperdx-otel-collector ──┐
                                    ▼
                            ┌───────────────┐     S3 API      ┌──────────┐
                            │  ClickHouse   │ ───────────────▶│  RustFS  │
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
| RustFS console   | http://localhost:9001   | `rustfsadmin` / `rustfsadmin` |
| OTLP gRPC        | localhost:4317          | —                          |
| OTLP HTTP        | localhost:4318          | —                          |

---

## What's actually running

```
$ docker compose ps
NAME            IMAGE                                            STATUS
clickhouse      clickhouse/clickhouse-server:latest              Up (healthy)
rustfs          rustfs/rustfs:latest                             Up (healthy)
rustfs-init     rustfs/rc:latest                                 Exited (0)      ← one-shot
hyperdx-otel    docker.hyperdx.io/.../hyperdx-otel-collector     Up (healthy)
hyperdx         hyperdx/hyperdx:latest                           Up (healthy)
hyperdx-mongo   mongo:9                                          Up
```

`rustfs-init` is deliberately a one-shot: it uses `rc` to create the `clickhouse` bucket and a `clickhouse` service account, then exits. ClickHouse depends on it via `service_completed_successfully` so the first boot order is guaranteed.

---

## Tour: ClickHouse storage/compute separation

Run `./demo.sh ch`. Highlights:

### 1. ClickHouse knows about an S3-backed disk

```
▶ Which disks does ClickHouse know about?
┌─name──────┬─type──────────┬─path─────────────────────────────────┐
│ default   │ Local         │ /var/lib/clickhouse/                 │
│ s3_cache  │ ObjectStorage │ /var/lib/clickhouse/disks/s3_rustfs/ │
│ s3_rustfs │ ObjectStorage │ /var/lib/clickhouse/disks/s3_rustfs/ │
└───────────┴───────────────┴──────────────────────────────────────┘
```

`s3_rustfs` is the raw S3 disk pointed at `http://rustfs:9000/clickhouse/data/`. `s3_cache` wraps it with a 10 GiB local cache (`clickhouse/config.d/storage.xml`).

### 2. New MergeTree tables land on S3 by default

```
▶ Prove the parts actually sit on the S3 disk
┌─disk_name─┬─parts─┬─size─────┐
│ s3_cache  │     1 │ 8.10 MiB │
└───────────┴───────┴──────────┘
```

### 3. The bytes are really in RustFS

The script spins up a disposable `amazon/aws-cli` container and lists the bucket:

```
▶ List what RustFS has under the clickhouse/ bucket
2026-10-12 14:30:11    1.2 KiB data/vxu/rpqixnj...
2026-10-12 14:30:11    7.8 MiB data/aky/htknacu...
...
Total Objects: 42
   Total Size: 8.1 MiB
```

You can also open the RustFS console at <http://localhost:9001> and browse the `clickhouse` bucket.

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

The second number is bytes served from `s3_cache` instead of RustFS.

### 5. Incremental aggregation with a materialized view

```
▶ Read from the rollup (sumMerge finalizes the aggregate state)
┌──────────────minute─┬───total─┐
│ 2026-10-12 14:39:00 │ 2100000 │
└─────────────────────┴─────────┘
```

The MV updates on every `INSERT` into `demo.events`; the target table (`AggregatingMergeTree`) also sits on S3.

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
│   └── config.d/
│       ├── storage.xml                 # S3 disk + cache + default policy
│       └── listen.xml                  # bind to 0.0.0.0 (else container-local only)
├── demo.sh                             # the guided tour
└── README.md
```

---

## Resets & gotchas

- **Full reset:** `docker compose down -v` (wipes RustFS data, ClickHouse data, Mongo state).
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

- **Compute scales independently of storage.** Blow away the ClickHouse container, keep the RustFS volume, start a new ClickHouse pointing at the same bucket — your data is still there.
- **RustFS is API-compatible with S3/MinIO**, so this topology maps 1:1 to a production setup against AWS S3, GCS (via S3 interop), or MinIO — just change the endpoint.
- **ClickStack reuses the same ClickHouse** as your analytical workload, instead of standing up a separate Elasticsearch/Loki/Prometheus for observability.
