# OpenTelemetry Collector Helm Chart (GKE)

Runs OpenTelemetry Collector on GKE with:

- **Edge collector (DaemonSet)** – one pod per node; receives OTLP and publishes to **Kafka**, **NATS**, or OTLP to the downstream.
- **Downstream collector (Deployment)** – receives from the edge (Kafka, NATS, or OTLP) and exports to **GCP** and **ClickHouse**.

## Architecture

```
[Pods] --OTLP--> [Edge DaemonSet] --Kafka / NATS / OTLP--> [Downstream] --> GCP + ClickHouse
```

- **Default (`queueBackend: otlp`):** Edge sends OTLP to the downstream; no broker required.
- **Kafka:** Set `edge.queueBackend: "kafka"` and `downstream.useKafkaReceiver: true`. Uses the standard contrib image.
- **NATS:** Set `edge.queueBackend: "nats"`; NATS exporter/receiver are not yet in upstream contrib.

## Prerequisites

- Kubernetes 1.23+ (GKE)
- **Kafka** (optional): if using `edge.queueBackend: "kafka"` (e.g. Strimzi or Bitnami Kafka).
- **NATS** (optional): if using NATS (NATS components not in standard contrib yet).
- **ClickHouse**: reachable from the cluster (e.g. `clickhouse.clickhouse.svc.cluster.local:9000`).
- **GCP**: project with Cloud Trace, Cloud Monitoring, and Cloud Logging APIs enabled; use Workload Identity or a service account key for the downstream collector.

## Install

1. Create a namespace (e.g. `observability`).
2. Ensure NATS and ClickHouse are deployed and reachable if you use them.
3. Configure GCP (Workload Identity recommended on GKE):

```yaml
# values override
serviceAccount:
  create: true
  annotations:
    iam.gke.io/gcp-service-account: YOUR_GCP_SA@YOUR_PROJECT.iam.gserviceaccount.com

downstream:
  gcp:
    enabled: true
    project: "your-gcp-project"
  clickhouse:
    enabled: true
    endpoint: "tcp://clickhouse.clickhouse.svc.cluster.local:9000"
    database: "otel"
```

4. Install the chart:

```bash
helm install otel-collector ./otel-collector -n observability --create-namespace -f my-values.yaml
```

## Sending telemetry to the edge

Point OTLP (gRPC `4317` or HTTP `4318`) at the edge collector. On GKE, use the edge **headless** service so each pod can reach the local node’s collector:

- **In-cluster:** `http://<release-name>-edge.observability.svc.cluster.local:4318` (or the same with `:4317` for gRPC). Because the edge is a DaemonSet, you can also use the per-node hostname or a local sidecar.

For node-local delivery, send to `localhost:4317` / `localhost:4318` when the app runs as a sidecar next to the edge, or use the edge service and rely on the DaemonSet placement.

## Values (high level)

| Section | Purpose |
|--------|---------|
| `edge.enabled` | Deploy the edge DaemonSet (default: true). |
| `edge.queueBackend` | `"otlp"` (default), `"kafka"`, or `"nats"`. How the edge sends data. |
| `edge.kafka` | Brokers, topics, encoding when `queueBackend` is `kafka`. |
| `edge.nats` | URL and subjects when `queueBackend` is `nats`. |
| `edge.downstreamEndpoint` | Override OTLP endpoint when `queueBackend` is `otlp`. |
| `downstream.useKafkaReceiver` | Consume from Kafka (set `true` with `edge.queueBackend: kafka`). |
| `downstream.kafka` | Brokers, topics, `groupId` for Kafka consumer. |
| `downstream.gcp.enabled` | Export to GCP (default: true). |
| `downstream.clickhouse.enabled` | Export to ClickHouse (default: true). |
| `downstream.debugExporter.enabled` | Log telemetry to stdout (default: false). Use for local testing when GCP/ClickHouse are disabled. |
| `serviceAccount.annotations` | For GKE Workload Identity. |

### Using Kafka

Use Kafka between edge and downstream with the standard contrib image:

```yaml
edge:
  queueBackend: "kafka"
  kafka:
    brokers: ["kafka-bootstrap.kafka.svc.cluster.local:9092"]

downstream:
  useKafkaReceiver: true
  kafka:
    brokers: ["kafka-bootstrap.kafka.svc.cluster.local:9092"]
    groupId: "otel-collector-downstream"
```

Create the topics `telemetry.traces`, `telemetry.metrics`, `telemetry.logs` in Kafka (or enable auto-create).

When using Kafka, the edge exporter sets **`partition_traces_by_id: true`** (config: `edge.kafka.partitionTracesById`, default true). Kafka then uses trace_id as the message key, so all spans of the same trace go to the same partition and thus to the same downstream consumer. That way tail-based sampling in the downstream sees full traces even with multiple replicas.

**Audit logs only via Kafka:** To send only logs with a specific attribute (e.g. type=audit) through Kafka and everything else (traces, metrics, other logs) directly to the downstream via OTLP, set:

```yaml
edge:
  queueBackend: "kafka"
  kafka:
    brokers: ["kafka-bootstrap.kafka.svc.cluster.local:9092"]
    auditLogsOnly: true
    auditLogAttributeKey: "type"    # log attribute name
    auditLogAttributeValue: "audit" # value that identifies audit logs

downstream:
  useKafkaReceiver: true
  kafkaAuditLogsOnlyMode: true
  kafka:
    brokers: ["kafka-bootstrap.kafka.svc.cluster.local:9092"]
```

Only the `telemetry.logs` topic is used; traces and metrics go edge → OTLP → downstream. Ensure log records that should be treated as audit have the matching attribute (e.g. `attributes["type"] = "audit"`).

### Persistent queue (data durability)

By default, both edge and downstream use a **disk-backed exporter queue** (OpenTelemetry `file_storage` extension + `sending_queue.storage`). Data in the exporter queue is written to a volume so it can survive pod restarts and be retried after crash recovery.

- **Edge:** `edge.persistentQueue.enabled` (default: true), `edge.persistentQueue.directory` (default: `/var/lib/otelcol/queue`), `edge.persistentQueue.queueSize` (default: 5000). Uses an `emptyDir` volume by default; data survives container restarts but is lost if the pod is evicted. For durability across pod replacement, use Kafka between edge and downstream, or enable **`edge.persistentQueue.pvc.enabled`** with a **ReadWriteMany** storage class (each DaemonSet pod uses a subdir named by pod name).
- **Downstream:** `downstream.persistentQueue.enabled`, `downstream.persistentQueue.directory`, `downstream.persistentQueue.queueSize` (same defaults). Same `emptyDir` behavior by default. Enable **`downstream.persistentQueue.pvc.enabled`** to use a PVC so the queue survives pod eviction; with replicas > 1 use a **ReadWriteMany** storage class (each replica uses a subdir by pod name).
- **PVC options:** When `persistentQueue.pvc.enabled` is true, set `pvc.size` (e.g. `10Gi`), optional `pvc.storageClassName`, and optionally `pvc.existingClaim` to use an existing PVC instead of creating one. The chart creates a PVC if `existingClaim` is not set.
- To disable: set `edge.persistentQueue.enabled: false` and/or `downstream.persistentQueue.enabled: false`.

### Tail-based sampling (traces only)

The downstream collector can run **tail-based sampling** on traces: it buffers spans by trace ID, waits for the trace to complete (or `decisionWait`), then applies policies and only exports traces that match (e.g. keep errors, keep slow, sample 10% of the rest). This reduces volume while keeping important traces.

- **Config:** `downstream.tailSampling.enabled` (default: true), `downstream.tailSampling.decisionWait`, `numTraces`, `expectedNewTracesPerSec`, and `downstream.tailSampling.policies`. Default policies: keep traces with status ERROR, keep traces with duration ≥ 500ms, then 10% probabilistic.
- **Full-trace guarantee:** With **Kafka** and `edge.kafka.partitionTracesById: true` (default), traces are partitioned by trace_id so each downstream replica receives complete traces for the partitions it consumes. With OTLP direct to multiple replicas, no such guarantee exists—use Kafka for correct tail-based sampling at scale.
- **Logs:** The OpenTelemetry Collector’s `tail_sampling` processor supports **traces only**, not logs.

## Data durability: remaining issues and mitigations

| Issue | Mitigation |
|-------|------------|
| **Batch processor in-memory** (edge & downstream) | Data in the batch processor is lost on hard crash (OOM, kill -9, node loss). **Fix:** Rely on graceful shutdown (90s + preStop) for clean terminations; right-size memory; use Kafka so data is durable once produced. |
| **Tail_sampling buffer** (downstream, traces) | Traces held in memory by tail_sampling are lost on crash (already consumed from Kafka). **Fix:** No disk option in the processor; minimize crashes and right-size `numTraces`/memory. Accept a small window of loss. |
| **Kafka producer acks** | If Kafka producer doesn’t wait for replication, data can be lost on broker failover. **Fix:** Chart sets `producer.requiredAcks: -1` (all) by default. Configure Kafka with replication factor ≥ 2 and `min.insync.replicas` ≥ 1 (e.g. 2). |
| **Kafka consumer offset** | If the receiver commits offsets before export, a crash loses consumed-but-not-exported data. **Fix:** Downstream uses persistent queue (and optional PVC) so export retries after restart; monitor consumer lag and export errors. |
| **Exporter queue full** | Long GCP/ClickHouse outage can fill the sending queue. **Fix:** Increase `persistentQueue.queueSize` and PVC size; monitor queue metrics and backend health. |
| **Edge queue lost on eviction** (no Kafka) | With OTLP only, edge queue is on emptyDir and is lost when the pod is evicted. **Fix:** Use Kafka so data is durable after produce, or enable `edge.persistentQueue.pvc.enabled` with a ReadWriteMany storage class. |
| **Multiple replicas + PVC** | One PVC with replicas > 1 requires ReadWriteMany. **Fix:** Chart uses ReadWriteMany when replicas > 1 for the downstream PVC; use a storage class that supports it (e.g. NFS, EFS) or set `replicas: 1`. |

## NATS note

The official OpenTelemetry Collector Contrib image does not yet include a NATS exporter or receiver (they are proposed). With `edge.queueBackend: "otlp"` or `"kafka"`, no NATS is required. To use NATS in the middle, you can:

1. Use a custom collector build that includes the NATS components when they are merged, or  
2. Run a small bridge that receives OTLP and publishes to NATS, and another that subscribes from NATS and exposes OTLP to the downstream collector.

## Testing locally

Use a local Kubernetes cluster (e.g. **kind**, **minikube**, or Docker Desktop Kubernetes) and the chart’s **debug exporter** so you don’t need GCP or ClickHouse.

### 1. Create a cluster and install the chart (debug only)

```bash
# Example: kind
kind create cluster --name otel-test

# Chart creates the observability namespace when createNamespace: true (default).
# Use --create-namespace so the namespace exists before the first install.
helm install otel-collector ./otel-collector -n observability --create-namespace -f - <<EOF
edge:
  queueBackend: "otlp"
downstream:
  gcp:
    enabled: false
  clickhouse:
    enabled: false
  debugExporter:
    enabled: true
    verbosity: basic
  tailSampling:
    enabled: false
EOF
```

Wait until the edge DaemonSet and downstream Deployment are ready (`kubectl get pods -n observability -w`).

### 2. Send OTLP to the edge

Port-forward the edge OTLP HTTP port and send a test trace (or use any OTLP-capable app):

```bash
kubectl port-forward -n observability svc/otel-collector-edge 4318:4318 &
# HTTP OTLP example (trace)
curl -s -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[{"resource":{},"scopeSpans":[{"scope":{},"spans":[{"traceId":"abc123","spanId":"def456","name":"test-span"}]}]}]}'
```

### 3. See telemetry in the downstream collector

Telemetry is forwarded edge → downstream and printed by the **debug** exporter. Check the downstream pod logs:

```bash
kubectl logs -n observability -l app.kubernetes.io/component=downstream -f
```

You should see trace (and/or metric/log) data in the logs.

### 4. Optional: test with Kafka and/or ClickHouse

**Kafka with Docker (apache/kafka:3.9.2)**

A `docker-compose.kafka.yml` is included to run a single-node Kafka (KRaft) on your host:

```bash
cd otel-collector
docker compose -f docker-compose.kafka.yml up -d
```

Then install or upgrade the chart so the edge and downstream use that broker. From **Docker Desktop Kubernetes**, pods can reach the host via `host.docker.internal`:

```bash
helm upgrade --install otel-collector . -n observability --create-namespace -f - <<EOF
edge:
  queueBackend: "kafka"
  kafka:
    brokers: ["host.docker.internal:9092"]
downstream:
  useKafkaReceiver: true
  kafka:
    brokers: ["host.docker.internal:9092"]
  gcp:
    enabled: false
  clickhouse:
    enabled: false
  debugExporter:
    enabled: true
EOF
```

Topics `telemetry.traces`, `telemetry.metrics`, and `telemetry.logs` will be created automatically when the edge first publishes (if your Kafka allows auto-create). Otherwise create them manually.

**Kafka in-cluster:** A standalone Helm chart in the repo uses the **Apache Kafka image** (`apache/kafka:3.9.2`). From the repo root:

```bash
helm install kafka ./kafka -n kafka --create-namespace
```

Broker address: `kafka-bootstrap.kafka.svc.cluster.local:9092`. Then install or upgrade the otel-collector chart with:

```yaml
edge:
  queueBackend: "kafka"
  kafka:
    brokers: ["kafka-bootstrap.kafka.svc.cluster.local:9092"]
downstream:
  useKafkaReceiver: true
  kafka:
    brokers: ["kafka-bootstrap.kafka.svc.cluster.local:9092"]
```

Topics `telemetry.traces`, `telemetry.metrics`, and `telemetry.logs` will be auto-created when the edge first publishes (if Kafka allows). See the [kafka chart README](../kafka/README.md) for values and uninstall.

Alternatively, install the Bitnami Kafka Helm chart (use a working image tag or registry override; the chart cannot be switched to `apache/kafka` without changing its templates, because Bitnami uses different configuration).

**ClickHouse:** Run ClickHouse (e.g. in-cluster or Docker) and set `downstream.clickhouse.enabled: true` and `downstream.clickhouse.endpoint` to the ClickHouse address. You can keep `debugExporter.enabled: true` to also see data in logs.

## End-to-end test (all changes)

Single flow to verify the chart: namespace creation, OTLP path, optional Kafka, and audit-logs-only mode. Run from the **repo root**. Use a local cluster (kind, minikube, or Docker Desktop K8s).

### Option A: OTLP only (no Kafka)

Chart creates the namespace when `createNamespace: true` (default).

```bash
# 1. Install (namespace is created by the chart)
helm upgrade --install otel-collector ./otel-collector -n observability --create-namespace -f - <<EOF
edge:
  queueBackend: "otlp"
downstream:
  gcp:
    enabled: false
  clickhouse:
    enabled: false
  debugExporter:
    enabled: true
  tailSampling:
    enabled: false
EOF

# 2. Wait for pods
kubectl get pods -n observability -w
# Ctrl+C when edge and downstream are Ready

# 3. Port-forward and send telemetry
kubectl port-forward -n observability svc/otel-collector-edge 4318:4318 &
sleep 2

# Trace
curl -s -X POST http://localhost:4318/v1/traces -H "Content-Type: application/json" \
  -d '{"resourceSpans":[{"resource":{},"scopeSpans":[{"scope":{},"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"test-span","kind":1,"startTimeUnixNano":"1544712660000000000","endTimeUnixNano":"1544712661000000000"}]}]}]}'

# Metric
curl -s -X POST http://localhost:4318/v1/metrics -H "Content-Type: application/json" \
  -d '{"resourceMetrics":[{"resource":{},"scopeMetrics":[{"scope":{},"metrics":[{"name":"test_metric","unit":"1","sum":{"dataPoints":[{"asDouble":42,"startTimeUnixNano":"1544712660000000000","timeUnixNano":"1544712661000000000"}],"aggregationTemporality":2}]}]}]}'

# Log (no audit attribute)
curl -s -X POST http://localhost:4318/v1/logs -H "Content-Type: application/json" \
  -d '{"resourceLogs":[{"resource":{},"scopeLogs":[{"scope":{},"logRecords":[{"timeUnixNano":"1544712661000000000","severityNumber":9,"severityText":"INFO","body":{"stringValue":"Regular log"}}]}]}]}'

# 4. Confirm in downstream logs
kubectl logs -n observability -l app.kubernetes.io/component=downstream -f --tail=100
# You should see the trace, metric, and log. Ctrl+C to stop.
```

### Option B: Audit-logs-only Kafka

Kafka only for logs with `type=audit`; traces, metrics, and other logs go edge → OTLP → downstream.

```bash
# 1. Start Kafka (pick one)
# Docker (host):
cd otel-collector && docker compose -f docker-compose.kafka.yml up -d && cd ..
# Or in-cluster:
helm upgrade --install kafka ./kafka -n kafka --create-namespace

# 2. Install/upgrade otel-collector with audit-logs-only
# Use host.docker.internal if Kafka is in Docker; use kafka-bootstrap.kafka.svc.cluster.local:9092 if Kafka is in-cluster.
helm upgrade --install otel-collector ./otel-collector -n observability --create-namespace -f - <<EOF
edge:
  queueBackend: "kafka"
  kafka:
    brokers: ["host.docker.internal:9092"]
    auditLogsOnly: true
    auditLogAttributeKey: "type"
    auditLogAttributeValue: "audit"
downstream:
  useKafkaReceiver: true
  kafkaAuditLogsOnlyMode: true
  kafka:
    brokers: ["host.docker.internal:9092"]
  gcp:
    enabled: false
  clickhouse:
    enabled: false
  debugExporter:
    enabled: true
EOF

# 3. Wait for pods
kubectl get pods -n observability -w
# Ctrl+C when ready

# 4. Port-forward and open downstream logs in another terminal
kubectl port-forward -n observability svc/otel-collector-edge 4318:4318 &
kubectl logs -n observability -l app.kubernetes.io/component=downstream -f --tail=50 &
sleep 2

# Non-audit log → goes edge → OTLP → downstream
curl -s -X POST http://localhost:4318/v1/logs -H "Content-Type: application/json" \
  -d '{"resourceLogs":[{"resource":{},"scopeLogs":[{"scope":{},"logRecords":[{"timeUnixNano":"1544712661000000000","severityNumber":9,"severityText":"INFO","body":{"stringValue":"Regular log"}}]}]}]}'

# Audit log → goes edge → Kafka → downstream
curl -s -X POST http://localhost:4318/v1/logs -H "Content-Type: application/json" \
  -d '{"resourceLogs":[{"resource":{},"scopeLogs":[{"scope":{},"logRecords":[{"timeUnixNano":"1544712662000000000","severityNumber":9,"severityText":"INFO","body":{"stringValue":"Audit event"},"attributes":[{"key":"type","value":{"stringValue":"audit"}}]}]}]}]}'

# Trace and metric → go edge → OTLP → downstream (no Kafka)
curl -s -X POST http://localhost:4318/v1/traces -H "Content-Type: application/json" \
  -d '{"resourceSpans":[{"resource":{},"scopeSpans":[{"scope":{},"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"test-span","kind":1,"startTimeUnixNano":"1544712660000000000","endTimeUnixNano":"1544712661000000000"}]}]}]}'
```

In the downstream log stream you should see: the regular log, the audit log, and the trace (all paths working).

### Cleanup

```bash
helm uninstall otel-collector -n observability
kubectl delete namespace observability
# If you used in-cluster Kafka:
helm uninstall kafka -n kafka
kubectl delete namespace kafka
```

## License

See repository license.
