{{/*
Expand the name of the chart.
*/}}
{{- define "plane.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "plane.fullname" -}}
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
Name of one component's resources, e.g. plane-api.
Usage: {{ include "plane.componentName" (dict "root" $ "component" "api") }}
*/}}
{{- define "plane.componentName" -}}
{{- printf "%s-%s" (include "plane.fullname" .root) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "plane.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "plane.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels. Shared by every component; each workload adds its own
app.kubernetes.io/component on top so the selectors stay disjoint.
*/}}
{{- define "plane.selectorLabels" -}}
app.kubernetes.io/name: {{ include "plane.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "plane.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "plane.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the secret holding SECRET_KEY, LIVE_SERVER_SECRET_KEY, DATABASE_URL and
RABBITMQ_PASSWORD -- either the one this chart renders or the external one.
*/}}
{{- define "plane.secretName" -}}
{{- if .Values.secrets.create }}
{{- printf "%s-secret" (include "plane.fullname" .) }}
{{- else }}
{{- required "secrets.create is false, so secrets.existingSecret must name the secret to consume" .Values.secrets.existingSecret }}
{{- end }}
{{- end }}

{{/*
Image reference for one component. image.repository is a prefix; the component's
own suffix completes it.
Usage: {{ include "plane.image" (dict "root" $ "suffix" "backend" "override" .Values.api.image) }}
*/}}
{{- define "plane.image" -}}
{{- if .override }}
{{- .override }}
{{- else }}
{{- $tag := .root.Values.image.tag | default .root.Chart.AppVersion }}
{{- printf "%s-%s:%s" .root.Values.image.repository .suffix $tag }}
{{- end }}
{{- end }}

{{/*
Environment sources for the components that run Plane application code. The
shared ConfigMap comes first so anything supplied through extraEnvFrom (the
externally managed secret) overrides it.
*/}}
{{- define "plane.envFrom" -}}
- configMapRef:
    name: {{ include "plane.fullname" . }}-config
{{- if .Values.secrets.create }}
- secretRef:
    name: {{ include "plane.secretName" . }}
{{- end }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end }}
