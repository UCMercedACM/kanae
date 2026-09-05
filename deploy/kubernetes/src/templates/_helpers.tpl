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
{{- printf "postgresql://postgres:%s@%s:5432/kanae" .Values.secrets.dbPassword .Values.serviceNames.database }}
{{- end }}
