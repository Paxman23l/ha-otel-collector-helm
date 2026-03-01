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
helm install otel-collector ./otel-collector -n observability -f my-values.yaml
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

### Persistent queue (data durability)

By default, both edge and downstream use a **disk-backed exporter queue** (OpenTelemetry `filestorage` extension + `sending_queue.storage`). Data in the exporter queue is written to a volume so it can survive pod restarts and be retried after crash recovery.

- **Edge:** `edge.persistentQueue.enabled` (default: true), `edge.persistentQueue.directory` (default: `/var/lib/otelcol/queue`), `edge.persistentQueue.queueSize` (default: 5000). Uses an `emptyDir` volume by default; data survives container restarts but is lost if the pod is evicted. For durability across pod replacement, use Kafka between edge and downstream, or enable **`edge.persistentQueue.pvc.enabled`** with a **ReadWriteMany** storage class (each DaemonSet pod uses a subdir named by pod name).
- **Downstream:** `downstream.persistentQueue.enabled`, `downstream.persistentQueue.directory`, `downstream.persistentQueue.queueSize` (same defaults). Same `emptyDir` behavior by default. Enable **`downstream.persistentQueue.pvc.enabled`** to use a PVC so the queue survives pod eviction; with replicas > 1 use a **ReadWriteMany** storage class (each replica uses a subdir by pod name).
- **PVC options:** When `persistentQueue.pvc.enabled` is true, set `pvc.size` (e.g. `10Gi`), optional `pvc.storageClassName`, and optionally `pvc.existingClaim` to use an existing PVC instead of creating one. The chart creates a PVC if `existingClaim` is not set.
- To disable: set `edge.persistentQueue.enabled: false` and/or `downstream.persistentQueue.enabled: false`.

### Tail-based sampling (traces only)

The downstream collector can run **tail-based sampling** on traces: it buffers spans by trace ID, waits for the trace to complete (or `decisionWait`), then applies policies and only exports traces that match (e.g. keep errors, keep slow, sample 10% of the rest). This reduces volume while keeping important traces.

- **Config:** `downstream.tailSampling.enabled` (default: true), `downstream.tailSampling.decisionWait`, `numTraces`, `expectedNewTracesPerSec`, and `downstream.tailSampling.policies`. Default policies: keep traces with status ERROR, keep traces with duration ≥ 500ms, then 10% probabilistic.
- **Full-trace guarantee:** With **Kafka** and `edge.kafka.partitionTracesById: true` (default), traces are partitioned by trace_id so each downstream replica receives complete traces for the partitions it consumes. With OTLP direct to multiple replicas, no such guarantee exists—use Kafka for correct tail-based sampling at scale.
- **Logs:** The OpenTelemetry Collector’s `tail_sampling` processor supports **traces only**, not logs.

## NATS note

The official OpenTelemetry Collector Contrib image does not yet include a NATS exporter or receiver (they are proposed). With `edge.queueBackend: "otlp"` or `"kafka"`, no NATS is required. To use NATS in the middle, you can:

1. Use a custom collector build that includes the NATS components when they are merged, or  
2. Run a small bridge that receives OTLP and publishes to NATS, and another that subscribes from NATS and exposes OTLP to the downstream collector.

## License

See repository license.
