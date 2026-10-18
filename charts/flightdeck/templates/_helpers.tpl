{{/* Chart name, truncated to the DNS label limit. */}}
{{- define "flightdeck.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Release-scoped base name; "flightdeck" for a release named flightdeck. */}}
{{- define "flightdeck.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/* Labels on every object. */}}
{{- define "flightdeck.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: flightdeck
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end }}

{{/*
Selector labels for one service. Call with (dict "root" $ "name" "gateway").
*/}}
{{- define "flightdeck.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/* Full object name for one service: <fullname>-<service>. */}}
{{- define "flightdeck.serviceName" -}}
{{- printf "%s-%s" (include "flightdeck.fullname" .root) .name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Redis master Service address from the subchart's fullnameOverride. */}}
{{- define "flightdeck.redisAddr" -}}
{{- printf "%s-master:6379" .Values.redis.fullnameOverride }}
{{- end }}
