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


{{- define "kanae.valkeyUri" }}
{{- printf "valkey://kanae:%s@%s:6379/" .Values.secrets.valkeyPassword .Values.serviceNames.valkey }}
{{- end }}


{{- define "kanae.kratosMigrateDsn" }}
{{- printf "postgres://kratos_migrate:%s@%s:5432/kratos?sslmode=disable&max_conns=5&max_idle_conns=2" .Values.secrets.kratosMigratePassword .Values.serviceNames.database }}
{{- end }}

{{- define "kanae.ketoMigrateDsn" }}
{{- printf "postgres://keto_migrate:%s@%s:5432/keto?sslmode=disable&max_conns=5&max_idle_conns=2" .Values.secrets.ketoMigratePassword .Values.serviceNames.database }}
{{- end }}


{{- define "kanae.kratosDsn" }}
{{- printf "postgres://kratos:%s@%s:5432/kratos?sslmode=disable&max_conns=20&max_idle_conns=4" .Values.secrets.kratosPassword .Values.serviceNames.database }}
{{- end }}

{{- define "kanae.ketoDsn" }}
{{- printf "postgres://keto:%s@%s:5432/keto?sslmode=disable&max_conns=20&max_idle_conns=4" .Values.secrets.ketoPassword .Values.serviceNames.database }}
{{- end }}


{{- define "kanae.kratosConfig" }}
{{- $config := include "kanae.file" (list . "kratos/kratos.prod.yml") }}
{{- $tokens := dict
      "${KRATOS_WEBHOOK_TOKEN_REGISTRATION}" .Values.secrets.kratosWebhookTokenRegistration
      "${KRATOS_WEBHOOK_TOKEN_SETTINGS}" .Values.secrets.kratosWebhookTokenSettings }}
{{- range $token, $value := $tokens }}
{{- if not (contains $token $config) }}
{{- fail (printf "%s is gone from kratos.prod.yml, so the placeholder would ship as the credential" $token) }}
{{- end }}
{{- $config = replace $token $value $config }}
{{- end }}
{{- $config }}
{{- end }}


{{- define "kanae.config" }}
{{- $config := include "kanae.file" (list . "config.dist.yml") | fromYaml }}
{{- $_ := set $config "postgres_uri" (include "kanae.postgresUri" .) }}
{{- $_ := set $config.kanae "allowed_origins" .Values.kanae.allowedOrigins }}
{{- $_ := set $config.kanae.limiter "enabled" .Values.kanae.limiter.enabled }}
{{- $_ := set $config.kanae.limiter "storage_uri" (include "kanae.valkeyUri" .) }}
{{- $_ := set $config.ory "kratos_public_url" (printf "http://%s:4433" .Values.serviceNames.kratos) }}
{{- $_ := set $config.ory "kratos_admin_url" (printf "http://%s:4434" .Values.serviceNames.kratos) }}
{{- $_ := set $config.ory "keto_read_url" (printf "http://%s:4466" .Values.serviceNames.keto) }}
{{- $_ := set $config.ory "keto_write_url" (printf "http://%s:4467" .Values.serviceNames.keto) }}
{{- $_ := set $config.ory "kratos_webhook_master_key" .Values.secrets.kratosWebhookMasterKey }}
{{- $_ := set $config.storage "key_id" .Values.secrets.storageKeyId }}
{{- $_ := set $config.storage "secret_key" .Values.secrets.storageSecretKey }}
{{- $config | toYaml }}
{{- end }}


{{- define "kanae.config.public" }}
{{- $config := include "kanae.config" . | fromYaml }}
{{- $_ := unset $config "postgres_uri" }}
{{- $_ := unset $config.kanae.limiter "storage_uri" }}
{{- $_ := unset $config.ory "kratos_webhook_master_key" }}
{{- $_ := unset $config.storage "key_id" }}
{{- $_ := unset $config.storage "secret_key" }}
{{- $config | toYaml }}
{{- end }}
