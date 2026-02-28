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
Edge exporter name: nats, kafka, or otlphttp based on queueBackend.
*/}}
{{- define "otel-collector.edgeExporterName" -}}
{{- if eq .Values.edge.queueBackend "nats" }}nats{{ else if eq .Values.edge.queueBackend "kafka" }}kafka_traces{{ else }}otlphttp{{ end }}
{{- end }}

{{- define "otel-collector.edgeTracesExporter" -}}
{{- if eq .Values.edge.queueBackend "kafka" }}kafka_traces{{ else if eq .Values.edge.queueBackend "nats" }}nats{{ else }}otlphttp{{ end }}
{{- end }}
{{- define "otel-collector.edgeMetricsExporter" -}}
{{- if eq .Values.edge.queueBackend "kafka" }}kafka_metrics{{ else if eq .Values.edge.queueBackend "nats" }}nats{{ else }}otlphttp{{ end }}
{{- end }}
{{- define "otel-collector.edgeLogsExporter" -}}
{{- if eq .Values.edge.queueBackend "kafka" }}kafka_logs{{ else if eq .Values.edge.queueBackend "nats" }}nats{{ else }}otlphttp{{ end }}
{{- end }}
