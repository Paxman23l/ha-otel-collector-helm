{{/*
Expand the name of the chart.
*/}}
{{- define "otel-collector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "otel-collector.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Edge collector full name (DaemonSet)
*/}}
{{- define "otel-collector.edgeFullname" -}}
{{- printf "%s-edge" (include "otel-collector.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Downstream collector full name (Deployment)
*/}}
{{- define "otel-collector.downstreamFullname" -}}
{{- printf "%s-downstream" (include "otel-collector.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "otel-collector.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "otel-collector.labels" -}}
helm.sh/chart: {{ include "otel-collector.chart" . }}
app.kubernetes.io/name: {{ include "otel-collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "otel-collector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "otel-collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "otel-collector.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "otel-collector.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Downstream OTLP endpoint URL for edge collector (when not using NATS).
*/}}
{{- define "otel-collector.downstreamOtlpEndpoint" -}}
{{- if .Values.edge.downstreamEndpoint }}{{ .Values.edge.downstreamEndpoint }}{{- else }}http://{{ include "otel-collector.downstreamFullname" . }}:4318{{- end }}
{{- end }}

{{/*
Downstream headless Service name (for loadbalancing exporter; resolves to pod IPs).
*/}}
{{- define "otel-collector.downstreamHeadlessServiceName" -}}
{{- printf "%s-headless" (include "otel-collector.downstreamFullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Downstream headless Service FQDN for DNS resolver (namespace.svc.cluster.local).
*/}}
{{- define "otel-collector.downstreamHeadlessHost" -}}
{{- printf "%s.%s.svc.cluster.local" (include "otel-collector.downstreamHeadlessServiceName" .) .Release.Namespace }}
{{- end }}

{{/*
Edge exporter name: nats, kafka, or otlphttp based on queueBackend.
*/}}
{{- define "otel-collector.edgeExporterName" -}}
{{- if eq .Values.edge.queueBackend "nats" }}nats{{ else if and (eq .Values.edge.queueBackend "kafka") .Values.edge.kafka.auditLogsOnly }}otlphttp{{ else if eq .Values.edge.queueBackend "kafka" }}kafka/traces{{ else }}otlphttp{{ end }}
{{- end }}

{{- define "otel-collector.edgeTracesExporter" -}}
{{- if and (eq .Values.edge.queueBackend "otlp") .Values.edge.otlpLoadBalancing }}loadbalancing{{ else if and (eq .Values.edge.queueBackend "kafka") .Values.edge.kafka.auditLogsOnly }}otlphttp{{ else if eq .Values.edge.queueBackend "kafka" }}kafka/traces{{ else if eq .Values.edge.queueBackend "nats" }}nats{{ else }}otlphttp{{ end }}
{{- end }}
{{- define "otel-collector.edgeMetricsExporter" -}}
{{- if and (eq .Values.edge.queueBackend "kafka") .Values.edge.kafka.auditLogsOnly }}otlphttp{{ else if eq .Values.edge.queueBackend "kafka" }}kafka/metrics{{ else if eq .Values.edge.queueBackend "nats" }}nats{{ else }}otlphttp{{ end }}
{{- end }}
{{- define "otel-collector.edgeLogsExporter" -}}
{{- if and (eq .Values.edge.queueBackend "kafka") .Values.edge.kafka.auditLogsOnly }}otlphttp{{ else if eq .Values.edge.queueBackend "kafka" }}kafka/logs{{ else if eq .Values.edge.queueBackend "nats" }}nats{{ else }}otlphttp{{ end }}
{{- end }}

{{/* Downstream pipeline exporters: debug, googlecloud, clickhouse. At least one must be enabled. */}}
{{- define "otel-collector.downstreamExporters" -}}
{{- $parts := list -}}
{{- if .Values.downstream.debugExporter.enabled -}}{{- $parts = append $parts "debug" -}}{{- end -}}
{{- if .Values.downstream.gcp.enabled -}}{{- $parts = append $parts "googlecloud" -}}{{- end -}}
{{- if .Values.downstream.clickhouse.enabled -}}{{- $parts = append $parts "clickhouse" -}}{{- end -}}
{{- join ", " $parts -}}
{{- end }}
