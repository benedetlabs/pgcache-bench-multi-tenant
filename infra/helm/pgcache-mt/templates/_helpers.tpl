{{/*
Expand the name of the chart.
*/}}
{{- define "pgcache-mt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Format allowed tables: handles both list and comma-separated string safely.
*/}}
{{- define "pgcache-mt.allowedTables" -}}
{{- if kindIs "slice" .Values.pgcache.allowedTables -}}
{{- join "," .Values.pgcache.allowedTables -}}
{{- else -}}
{{- .Values.pgcache.allowedTables -}}
{{- end -}}
{{- end }}
