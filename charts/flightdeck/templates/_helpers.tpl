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

{{/*
Bytes for a Kubernetes memory quantity in Ki/Mi/Gi (or plain bytes).
Call with the quantity string; returns an integer as a string.
*/}}
{{- define "flightdeck.memBytes" -}}
{{- $q := toString . -}}
{{- $n := regexFind "^[0-9]+" $q | int64 -}}
{{- if hasSuffix "Gi" $q }}{{ mul $n 1073741824 }}
{{- else if hasSuffix "Mi" $q }}{{ mul $n 1048576 }}
{{- else if hasSuffix "Ki" $q }}{{ mul $n 1024 }}
{{- else if regexMatch "^[0-9]+$" $q }}{{ $n }}
{{- else }}{{ fail (printf "unsupported memory quantity %q: use Ki, Mi, Gi or bytes" $q) }}
{{- end }}
{{- end }}

{{/* Redis master Service address from the subchart's fullnameOverride. */}}
{{- define "flightdeck.redisAddr" -}}
{{- printf "%s-master:6379" .Values.redis.fullnameOverride }}
{{- end }}
