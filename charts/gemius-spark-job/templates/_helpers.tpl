{{- define "gemius-job.name" -}}
{{- .Values.nameOverride | trunc 48 | trimSuffix "-" -}}
{{- end }}

{{- define "gemius-job.namespace" -}}
{{- default (printf "spark-%s" .Values.group) .Values.namespace -}}
{{- end }}

{{- define "gemius-job.queue" -}}
{{- default (printf "root.spark-%s" .Values.group) .Values.queue -}}
{{- end }}

{{- define "gemius-job.image" -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end }}

{{- define "gemius-job.labels" -}}
app.kubernetes.io/name: {{ include "gemius-job.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: gemius-spark
spark.gemius.io/group: {{ .Values.group | quote }}
spark.gemius.io/operator: {{ .Values.operator | quote }}
{{- end }}

{{- define "gemius-job.securityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
runAsGroup: 185
runAsUser: 185
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}
