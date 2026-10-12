#!/usr/bin/env bash
# demo.sh — guided tour of ClickHouse (storage/compute separation on MinIO)
# and ClickStack (HyperDX observability).
#
# Usage:  ./demo.sh           # run all sections, pausing between each
#         ./demo.sh ch        # ClickHouse sections only
#         ./demo.sh otel      # ClickStack / OTel sections only
#         STEP=0 ./demo.sh    # run without pausing

set -euo pipefail

# ---------- config ----------
CH_URL="http://localhost:8123"
CH_USER="default"
CH_PASS="clickhouse"
OTLP_HTTP="http://localhost:4318"
MINIO_S3="http://localhost:9000"
MINIO_KEY="clickhouse"
MINIO_SECRET="clickhouse-secret"
BUCKET="clickhouse"
HYPERDX_URL="http://localhost:8080"

# ---------- pretty printing ----------
if [ -t 1 ]; then
  B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; C=$'\e[36m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
else
  B=""; D=""; G=""; C=""; Y=""; R=""; N=""
fi

section() { printf "\n${B}${C}━━━ %s ━━━${N}\n" "$*"; }
step()    { printf "\n${B}${G}▶ %s${N}\n" "$*"; }
note()    { printf "${D}%s${N}\n" "$*"; }
run()     { printf "${Y}\$ %s${N}\n" "$*"; eval "$@"; }
pause()   { [ "${STEP:-1}" = "0" ] && return; printf "\n${D}[enter to continue]${N} "; read -r _; }

ch() { curl -sS -u "${CH_USER}:${CH_PASS}" "${CH_URL}/?default_format=PrettyCompact" --data-binary "$*"; }
ch_raw() { curl -sS -u "${CH_USER}:${CH_PASS}" "${CH_URL}/" --data-binary "$*"; }

# ---------- preflight ----------
preflight() {
  section "Preflight"
  for svc in clickhouse minio hyperdx-otel hyperdx; do
    if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
      printf "  ${G}✓${N} %s\n" "$svc"
    else
      printf "  ${R}✗${N} %s is not running — run: docker compose up -d\n" "$svc"; exit 1
    fi
  done
  ch "SELECT version()" >/dev/null || { echo "ClickHouse not reachable"; exit 1; }
}

# =============================================================
# PART 1 — ClickHouse: separation of storage and compute
# =============================================================
ch_storage_policy() {
  section "ClickHouse · storage policies & disks"

  step "Which disks does ClickHouse know about?"
  run "ch \"SELECT name, type, path FROM system.disks\""
  note "s3_minio = raw S3 disk. s3_cache = local read cache in front. s3_minio_packed = plain_rewritable."

  step "Which storage policy is default?"
  run "ch \"SELECT policy_name, volume_name, disks FROM system.storage_policies\""
  pause
}

ch_create_table() {
  section "ClickHouse · create a MergeTree whose data lives on MinIO"

  step "Create a table (uses the default s3_main policy)"
  run "ch \"DROP TABLE IF EXISTS demo.events\""
  run "ch \"CREATE DATABASE IF NOT EXISTS demo\""
  run "ch \"CREATE TABLE demo.events (
         ts     DateTime64(3),
         user   String,
         action LowCardinality(String),
         amount Float64
       ) ENGINE = MergeTree ORDER BY (user, ts)\""

  step "Insert 1 million rows (generated server-side)"
  run "ch \"INSERT INTO demo.events
         SELECT now() - number/100,
                concat('user_', toString(number % 10000)),
                arrayElement(['view','click','buy','refund'], (number % 4) + 1),
                rand() / 1e8
         FROM numbers(1000000)\""

  step "Prove the parts actually sit on the S3 disk"
  run "ch \"SELECT disk_name, count() parts, formatReadableSize(sum(bytes_on_disk)) size
         FROM system.parts
         WHERE database='demo' AND table='events' AND active
         GROUP BY disk_name\""
  pause
}

ch_proof_on_rustfs() {
  section "ClickHouse · see the bytes on MinIO"

  step "List what MinIO has under the clickhouse/ bucket (via aws CLI container)"
  run "docker run --rm --network clickhouse-stack_default \
         -e AWS_ACCESS_KEY_ID=${MINIO_KEY} \
         -e AWS_SECRET_ACCESS_KEY=${MINIO_SECRET} \
         -e AWS_DEFAULT_REGION=us-east-1 \
         amazon/aws-cli --endpoint-url http://minio:9000 \
         s3 ls --recursive --summarize --human-readable s3://${BUCKET}/data/ 2>/dev/null | tail -n 15"
  note "Every one of those objects is a MergeTree part living on object storage, not local disk."
  pause
}

ch_queries() {
  section "ClickHouse · analytics on the S3-backed table"

  step "Top actions by count (full scan, served from the cache in front of S3)"
  run "ch \"SELECT action, count() c, round(avg(amount),2) avg_amt
         FROM demo.events GROUP BY action ORDER BY c DESC\""

  step "Per-minute buy volume for the last 10 minutes"
  run "ch \"SELECT toStartOfMinute(ts) minute, sum(amount) total
         FROM demo.events
         WHERE action='buy' AND ts > now() - INTERVAL 10 MINUTE
         GROUP BY minute ORDER BY minute\""

  step "Query that just ran — look at the cache stats"
  ch_raw "SYSTEM FLUSH LOGS" >/dev/null
  run "ch \"SELECT query_duration_ms, read_rows, formatReadableSize(read_bytes) read_bytes,
                ProfileEvents['CachedReadBufferReadFromCacheBytes'] cache_hit_bytes
         FROM system.query_log
         WHERE type='QueryFinish' AND query LIKE 'SELECT action%'
         ORDER BY event_time DESC LIMIT 1\""
  pause
}

ch_materialized_view() {
  section "ClickHouse · materialized view (incremental aggregation)"

  step "Target table + MV that rolls up buys per minute as new data lands"
  run "ch \"DROP TABLE IF EXISTS demo.buys_per_min\""
  run "ch \"DROP VIEW  IF EXISTS demo.mv_buys_per_min\""
  run "ch \"CREATE TABLE demo.buys_per_min (
         minute DateTime,
         total  AggregateFunction(sum, Float64)
       ) ENGINE = AggregatingMergeTree ORDER BY minute\""
  run "ch \"CREATE MATERIALIZED VIEW demo.mv_buys_per_min TO demo.buys_per_min AS
         SELECT toStartOfMinute(ts) minute, sumState(amount) total
         FROM demo.events WHERE action='buy' GROUP BY minute\""

  step "Insert more rows — the MV updates incrementally"
  run "ch \"INSERT INTO demo.events SELECT now(), 'user_demo', 'buy', 42 FROM numbers(50000)\""

  step "Read from the rollup (sumMerge finalizes the aggregate state)"
  run "ch \"SELECT minute, sumMerge(total) total
         FROM demo.buys_per_min
         GROUP BY minute ORDER BY minute DESC LIMIT 5\""
  pause
}

# =============================================================
# PART 2 — ClickStack: send telemetry via OTLP, query it
# =============================================================
otlp_send_logs() {
  section "ClickStack · send OpenTelemetry logs over OTLP/HTTP"

  local ts_ns; ts_ns=$(( $(date +%s) * 1000000000 ))
  step "POST a few logs to the collector at ${OTLP_HTTP}/v1/logs"
  run "curl -sS -X POST ${OTLP_HTTP}/v1/logs -H 'Content-Type: application/json' -d '{
    \"resourceLogs\": [{
      \"resource\": { \"attributes\": [
        {\"key\":\"service.name\",\"value\":{\"stringValue\":\"demo-shop\"}},
        {\"key\":\"deployment.environment\",\"value\":{\"stringValue\":\"demo\"}}
      ]},
      \"scopeLogs\": [{
        \"scope\": {\"name\":\"demo.sh\"},
        \"logRecords\": [
          {\"timeUnixNano\":\"${ts_ns}\",\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"checkout started for user_42\"}},
          {\"timeUnixNano\":\"${ts_ns}\",\"severityText\":\"WARN\",\"body\":{\"stringValue\":\"inventory low for sku_7\"}},
          {\"timeUnixNano\":\"${ts_ns}\",\"severityText\":\"ERROR\",\"body\":{\"stringValue\":\"payment gateway timeout\"}}
        ]
      }]
    }]
  }' | sed 's/^/   /'"

  sleep 5
  step "Verify in ClickHouse"
  run "ch \"SELECT SeverityText, ServiceName, Body FROM default.otel_logs ORDER BY Timestamp DESC LIMIT 5\""
  pause
}

otlp_send_trace() {
  section "ClickStack · send a distributed trace"

  local tid sid1 sid2 start end
  tid=$(openssl rand -hex 16); sid1=$(openssl rand -hex 8); sid2=$(openssl rand -hex 8)
  start=$(( $(date +%s) * 1000000000 ))
  end=$(( start + 120000000 ))  # +120ms

  step "POST two spans (checkout -> charge) to ${OTLP_HTTP}/v1/traces"
  run "curl -sS -X POST ${OTLP_HTTP}/v1/traces -H 'Content-Type: application/json' -d '{
    \"resourceSpans\": [{
      \"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"demo-shop\"}}]},
      \"scopeSpans\":[{\"scope\":{\"name\":\"demo.sh\"},\"spans\":[
        {\"traceId\":\"${tid}\",\"spanId\":\"${sid1}\",\"name\":\"checkout\",\"kind\":2,
         \"startTimeUnixNano\":\"${start}\",\"endTimeUnixNano\":\"${end}\",
         \"attributes\":[{\"key\":\"user\",\"value\":{\"stringValue\":\"user_42\"}}]},
        {\"traceId\":\"${tid}\",\"spanId\":\"${sid2}\",\"parentSpanId\":\"${sid1}\",
         \"name\":\"charge\",\"kind\":3,
         \"startTimeUnixNano\":\"${start}\",\"endTimeUnixNano\":\"${end}\",
         \"attributes\":[{\"key\":\"amount\",\"value\":{\"doubleValue\":99.5}}]}
      ]}]
    }]
  }' | sed 's/^/   /'"

  sleep 5
  step "Verify in ClickHouse"
  run "ch \"SELECT ServiceName, SpanName, SpanKind, Duration/1e6 duration_ms
          FROM default.otel_traces
          WHERE TraceId='${tid}' ORDER BY Timestamp\""
  note "In HyperDX, open Search → source 'Traces' and search TraceId=${tid} to see the waterfall."
  pause
}

otlp_send_metric() {
  section "ClickStack · send a gauge metric"

  local ts_ns; ts_ns=$(( $(date +%s) * 1000000000 ))
  step "POST a gauge sample"
  run "curl -sS -X POST ${OTLP_HTTP}/v1/metrics -H 'Content-Type: application/json' -d '{
    \"resourceMetrics\":[{
      \"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"demo-shop\"}}]},
      \"scopeMetrics\":[{\"scope\":{\"name\":\"demo.sh\"},\"metrics\":[{
        \"name\":\"shop.cart.value\",\"unit\":\"USD\",
        \"gauge\":{\"dataPoints\":[{\"timeUnixNano\":\"${ts_ns}\",\"asDouble\":123.45,
          \"attributes\":[{\"key\":\"region\",\"value\":{\"stringValue\":\"us-east\"}}]}]}
      }]}]
    }]
  }' | sed 's/^/   /'"

  sleep 5
  step "Verify in ClickHouse"
  run "ch \"SELECT MetricName, Value, Attributes
          FROM default.otel_metrics_gauge ORDER BY TimeUnix DESC LIMIT 3\""
  pause
}

hyperdx_pointer() {
  section "ClickStack · explore in the HyperDX UI"
  note "Open: ${HYPERDX_URL}"
  note "  • Search          → pick Logs/Traces/Metrics, filter by service=demo-shop"
  note "  • Service Map     → see demo-shop appear once a few spans flow"
  note "  • Dashboards      → build charts off the preseeded sources"
  note "  • Chart Explorer  → ad-hoc queries directly over ClickHouse"
  pause
}

# =============================================================
# driver
# =============================================================
s3_ls() {  # list objects under a prefix via a disposable aws-cli container
  docker run --rm --network clickhouse-stack_default \
    -e AWS_ACCESS_KEY_ID=${MINIO_KEY} \
    -e AWS_SECRET_ACCESS_KEY=${MINIO_SECRET} \
    -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli --endpoint-url http://minio:9000 \
    s3 ls --recursive --summarize "s3://${BUCKET}/$1/" 2>/dev/null
}

ch_cost_tuning() {
  section "ClickHouse · cost tuning (fewer, bigger S3 objects)"

  note "Three techniques active in this stack:"
  note "  1. async_insert=1    — buffer many tiny INSERTs server-side."
  note "  2. compact parts     — one file per part instead of per column."
  note "  3. s3_packed policy  — plain_rewritable metadata lives IN the bucket"
  note "                         (no local sidecar), typically ~10x fewer S3"
  note "                         objects vs the standard disk."

  step "Confirm async_insert is on"
  run "ch \"SELECT name, value FROM system.settings
         WHERE name IN ('async_insert','wait_for_async_insert',
                        'async_insert_max_data_size','async_insert_busy_timeout_ms')\""

  step "Both policies available?"
  run "ch \"SELECT policy_name, disks FROM system.storage_policies
         WHERE policy_name IN ('s3_main','s3_packed')\""

  step "Create a 'default' table (s3_main policy, normal metadata)"
  run "ch \"CREATE DATABASE IF NOT EXISTS demo\""
  run "ch \"DROP TABLE IF EXISTS demo.events_default\""
  run "ch \"CREATE TABLE demo.events_default (
         ts DateTime64(3), user String,
         action LowCardinality(String), amount Float64
       ) ENGINE = MergeTree ORDER BY (user, ts)\""

  step "Create a 'packed' table (s3_packed policy, one object per part)"
  run "ch \"DROP TABLE IF EXISTS demo.events_packed\""
  run "ch \"CREATE TABLE demo.events_packed (
         ts DateTime64(3), user String,
         action LowCardinality(String), amount Float64
       ) ENGINE = MergeTree ORDER BY (user, ts)
       SETTINGS storage_policy='s3_packed',
                min_bytes_for_wide_part=1073741824,
                min_bytes_for_full_part_storage=1073741824\""

  step "Fire 200 small INSERTs at each table"
  run "for i in \$(seq 1 200); do
         ch_raw \"INSERT INTO demo.events_default
                  SELECT now(), concat('u_',toString(number)), 'buy', 1.0
                  FROM numbers(500)\" >/dev/null;
         ch_raw \"INSERT INTO demo.events_packed
                  SELECT now(), concat('u_',toString(number)), 'buy', 1.0
                  FROM numbers(500)\" >/dev/null;
       done"
  sleep 4  # let async_insert flush

  step "Parts in ClickHouse (same 200 inserts → same part count on both)"
  run "ch \"SELECT table, disk_name, part_type, count() parts
         FROM system.parts
         WHERE database='demo' AND table IN ('events_default','events_packed') AND active
         GROUP BY table, disk_name, part_type ORDER BY table\""

  step "Actual S3 objects on MinIO per prefix"
  printf '   %sdefault (s3_main):%s\n' "$B" "$N"
  s3_ls data   | tail -n 2 | sed 's/^/     /'
  printf '   %spacked (s3_packed):%s\n' "$B" "$N"
  s3_ls packed | tail -n 2 | sed 's/^/     /'
  note "Example on this run: default=5035 objects vs packed=490 objects for"
  note "the same workload — ~10x reduction in S3 PUTs and object count."
  pause
}

run_ch()   { ch_storage_policy; ch_create_table; ch_proof_on_rustfs; ch_queries; ch_materialized_view; ch_cost_tuning; }
run_otel() { otlp_send_logs; otlp_send_trace; otlp_send_metric; hyperdx_pointer; }

preflight
case "${1:-all}" in
  ch)   run_ch ;;
  otel) run_otel ;;
  all)  run_ch; run_otel ;;
  *)    echo "usage: $0 [all|ch|otel]"; exit 2 ;;
esac

section "Done"
note "ClickHouse HTTP:   ${CH_URL}   (user=${CH_USER})"
note "MinIO console:    http://localhost:9001"
note "HyperDX UI:        ${HYPERDX_URL}"
