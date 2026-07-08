{{/* 앱 이름이 길어서(dev-temporal-{svc}-worker-{name}) 63자 truncate 필수 */}}
{{- define "temporal-worker.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "temporal-worker.labels" -}}
app.kubernetes.io/name: {{ include "temporal-worker.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: worker
app.kubernetes.io/part-of: temporal-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "temporal-worker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "temporal-worker.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* mTLS Secret 이름 — certManager면 이 차트가 만들 Secret, 아니면 existingSecret */}}
{{- define "temporal-worker.tlsSecretName" -}}
{{- if .Values.temporal.tls.certManager.enabled -}}
{{- printf "%s-tls" (include "temporal-worker.fullname" .) -}}
{{- else -}}
{{- .Values.temporal.tls.existingSecret -}}
{{- end -}}
{{- end -}}
