{{/*
  kanae.configYml — the rendered contents of /kanae/config.yml.

  This exists as a named template for exactly one reason: two places need the
  same bytes. templates/secrets.yaml puts them in the kanae-config Secret, and
  the kanae Deployment hashes them into a checksum/config annotation so a
  rotated secret or a changed setting actually rolls the pods. A checksum
  computed from anything other than the real rendered output silently stops
  matching the moment someone adds a key to the overlay, which is worse than no
  checksum at all.

  It is deliberately NOT the dict-argument style the migration Jobs were pulled
  out of: no parameters, one caller-visible behaviour, and the output is a plain
  YAML document you can read with `helm template`.

  The overlay is the same set of keys seed-k8s.sh patches with yq. Those two
  produce the same Secret by different routes, so they have to stay in step.
*/}}
{{- define "kanae.configYml" -}}
{{- $cfg := .Files.Get "files/config.dist.yml" | fromYaml }}
{{- $s := .Values.secrets }}
{{- $st := .Values.storage }}
{{- $overlay := dict
      "kanae" (dict
        "host" "0.0.0.0"
        "dev_mode" false
        "allowed_origins" .Values.kanae.allowedOrigins
        "prometheus" (dict "enabled" true "host" "0.0.0.0")
        "limiter" (dict "storage_uri" "valkey://valkey:6379/"))
      "ory" (dict
        "kratos_public_url" "http://kratos:4433"
        "kratos_admin_url"  "http://kratos:4434"
        "keto_read_url"     "http://keto:4466"
        "keto_write_url"    "http://keto:4467"
        "kratos_webhook_master_key" (required "secrets.kratosWebhookMasterKey is required" $s.kratosWebhookMasterKey))
      "storage" (dict
        "url"         (required "storage.url is required"        $st.url)
        "presign_url" (required "storage.presignUrl is required" $st.presignUrl)
        "region"      $st.region
        "bucket"      $st.bucket
        "key_id"      (required "secrets.storageKeyId is required"     $s.storageKeyId)
        "secret_key"  (required "secrets.storageSecretKey is required" $s.storageSecretKey)
        "public" (dict
          "bucket" $st.publicBucket
          "url"    (required "storage.publicUrl is required" $st.publicUrl)))
      "postgres_uri" (printf "postgresql://%s:%s@database:5432/%s"
        (required "secrets.dbUsername is required"     $s.dbUsername)
        (required "secrets.dbPassword is required"     $s.dbPassword)
        (required "secrets.dbDatabaseName is required" $s.dbDatabaseName))
}}
{{ mergeOverwrite $cfg $overlay | toYaml }}
{{- end -}}
