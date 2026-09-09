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


{{- define "kanae.atlasUrl" }}
{{- printf "postgres://kanae_migrate:$(KANAE_MIGRATE_PASSWORD)@%s:5432/kanae?search_path=public&sslmode=disable" .Values.serviceNames.database }}
{{- end }}

{{- define "kanae.atlasDevUrl" }}
{{- printf "postgres://kanae_migrate:$(KANAE_MIGRATE_PASSWORD)@%s:5432/postgres?search_path=public&sslmode=disable" .Values.serviceNames.database }}
{{- end }}

{{- define "kanae.kratosMigrateDsn" }}
{{- printf "postgres://kratos_migrate:$(KRATOS_MIGRATE_PASSWORD)@%s:5432/kratos?sslmode=disable&max_conns=20&max_idle_conns=4" .Values.serviceNames.database }}
{{- end }}

{{- define "kanae.ketoMigrateDsn" }}
{{- printf "postgres://keto_migrate:$(KETO_MIGRATE_PASSWORD)@%s:5432/keto?sslmode=disable&max_conns=20&max_idle_conns=4" .Values.serviceNames.database }}
{{- end }}
