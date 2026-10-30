{{- define "magic.serverImage" -}}{{ .Values.images.server }}:{{ .Values.tag }}{{- end }}
{{- define "magic.webImage" -}}{{ .Values.images.web }}:{{ .Values.tag }}{{- end }}

{{/* The database address the server and the data tool read. */}}
{{- define "magic.databaseEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.existingSecret }}
      key: DATABASE_URL
{{- end }}

{{/* Runs as the image's own user; the volumes belong to its group. */}}
{{- define "magic.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  fsGroup: 10001
{{- end }}
