{{- /* To utilize this: {{ include "kanae.file" (list . "config.dist.yml") }} */}}
{{- define "kanae.file" }}
{{- $root := index . 0 }}
{{- $path := printf "files/%s" (index . 1) }}
{{- $content := $root.Files.Get $path }}
{{- if or (empty $content) (hasPrefix "../" $content) }}
{{- fail (printf "%s is empty or holds a bare path. Run 'mise run helm:files'" $path) }}
{{- end }}
{{- $content }}
{{- end }}


{{- define "kanae.postgresUri" }}
{{- printf "postgresql://kanae:%s@%s:5432/kanae" .Values.secrets.kanaePassword .Values.serviceNames.database }}
{{- end }}


{{- define "kanae.kratosMigrateDsn" }}
{{- printf "postgres://kratos_migrate:%s@%s:5432/kratos?sslmode=disable&max_conns=20&max_idle_conns=4" .Values.secrets.kratosMigratePassword .Values.serviceNames.database }}
{{- end }}

{{- define "kanae.ketoMigrateDsn" }}
{{- printf "postgres://keto_migrate:%s@%s:5432/keto?sslmode=disable&max_conns=20&max_idle_conns=4" .Values.secrets.ketoMigratePassword .Values.serviceNames.database }}
{{- end }}
