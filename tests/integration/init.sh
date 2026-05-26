#!/usr/bin/env bash
# Bootstrap the integration-test stack end-to-end:
#
#   1) docker/.env       — Kratos cookie/cipher + Garage RPC/admin/metrics secrets.
#   2) config.yml        — Kratos webhook master key + Garage S3 creds.
#   3) Kratos webhook tokens derived from the master key.
#   4) docker compose -f docker/docker-compose.test.yml up -d --wait.
#   5) Garage cluster init (layout/key/buckets/CORS/lifecycle).
#   6) Ory bootstrap — admin/manager/leads/member identities via the Kratos
#      admin REST API, matching `members` rows, Keto role tuples, and the
#      identity UUIDs appended to tests/hurl/vars.env for the Hurl scenarios.

set -euo pipefail

if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
	echo "init.sh must be run from inside the kanae git checkout" >&2
	exit 1
fi
cd "$ROOT"

COMPOSE_FILE="docker/docker-compose.test.yml"
ENV_FILE="docker/.env"
ENV_EXAMPLE="docker/example.env"
CONFIG_FILE="config.yml"
CONFIG_DIST="config.dist.yml"
HURL_VARS="tests/integration/vars.env"
HURL_SECRETS_FILE="tests/integration/secrets.env"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

for cmd in docker openssl yq uv curl jq; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		printf 'missing prerequisite: %s\n' "$cmd" >&2
		exit 1
	fi
done

### 1. Setup docker/.env
if [[ ! -f "$ENV_FILE" ]]; then
	log "creating $ENV_FILE from $ENV_EXAMPLE"
	cp "$ENV_EXAMPLE" "$ENV_FILE"

	sed -i "s|^CONFIG_LOCATION=.*|CONFIG_LOCATION=$ROOT/config.yml|" "$ENV_FILE"
	sed -i "s|^KRATOS_SECRETS_COOKIE=.*|KRATOS_SECRETS_COOKIE=$(openssl rand -hex 32)|" "$ENV_FILE"
	sed -i "s|^KRATOS_SECRETS_CIPHER=.*|KRATOS_SECRETS_CIPHER=$(openssl rand -hex 16)|" "$ENV_FILE"

	{
		printf '\nGARAGE_RPC_SECRET=%s\n' "$(openssl rand -hex 32)"
		printf 'GARAGE_ADMIN_TOKEN=%s\n' "$(openssl rand -base64 32)"
		printf 'GARAGE_METRICS_TOKEN=%s\n' "$(openssl rand -base64 32)"
	} >>"$ENV_FILE"
else
	log "$ENV_FILE already exists, leaving as-is"
fi

### 2. Setup config.yml
fresh_config=0
if [[ ! -f "$CONFIG_FILE" ]]; then
	log "creating $CONFIG_FILE from $CONFIG_DIST"
	cp "$CONFIG_DIST" "$CONFIG_FILE"

	webhook_key=$(uv run python -c "import secrets; print(secrets.token_hex(32))")

	garage_key_id="GK$(openssl rand -hex 16)"
	garage_secret_key=$(openssl rand -hex 32)

	key="$webhook_key" yq -i '.ory.kratos_webhook_master_key = strenv(key)' "$CONFIG_FILE"
	key="$garage_key_id" yq -i '.storage.key_id = strenv(key)' "$CONFIG_FILE"
	key="$garage_secret_key" yq -i '.storage.secret_key = strenv(key)' "$CONFIG_FILE"

	yq -i '.kanae.limiter.storage_uri = "valkey://valkey:6379/"' "$CONFIG_FILE"
	yq -i '.ory.kratos_public_url = "http://kratos:4433"' "$CONFIG_FILE"
	yq -i '.ory.kratos_admin_url = "http://kratos:4434"' "$CONFIG_FILE"
	yq -i '.ory.keto_read_url    = "http://keto:4466"' "$CONFIG_FILE"
	yq -i '.ory.keto_write_url   = "http://keto:4467"' "$CONFIG_FILE"
	yq -i '.storage.url          = "http://garage:3900"' "$CONFIG_FILE"
	yq -i '.postgres_uri = "postgresql://postgres:password@database:5432/kanae"' "$CONFIG_FILE"

	fresh_config=1
else
	log "$CONFIG_FILE already exists, leaving as-is"
fi

### 3. Derive per-hook Kratos webhook tokens from the master key into docker/.env.
log "deriving Kratos webhook tokens from master key"
uv run --with python-dotenv python scripts/derive-webhook-tokens.py

### 4. Bring up the docker stack and wait for healthchecks.
log "bringing up $COMPOSE_FILE"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --wait

if [[ -f "$HURL_SECRETS_FILE" ]]; then
	PASSWORD=$(grep '^PASSWORD=' "$HURL_SECRETS_FILE" | cut -d= -f2)
	log "reusing PASSWORD from existing $HURL_SECRETS_FILE"
else
	PASSWORD=$(openssl rand -hex 32)
fi
export PASSWORD

(
	### 5. Garage setup (mostly copied from `mise run garage:setup` with modifications)
	if [[ "$fresh_config" -eq 0 ]]; then
		log "config.yml pre-existed → skipping garage init (assumed already configured)"
	else
		log "configuring Garage cluster (layout / key / buckets / CORS / lifecycle)"

		GARAGE_KEY_ID=$(yq '.storage.key_id' "$CONFIG_FILE")
		GARAGE_SECRET_KEY=$(yq '.storage.secret_key' "$CONFIG_FILE")
		GARAGE_BUCKET=$(yq '.storage.bucket' "$CONFIG_FILE")
		GARAGE_PUBLIC_BUCKET=$(yq '.storage.public.bucket' "$CONFIG_FILE")
		GARAGE_URL="http://localhost:3900"
		export AWS_ACCESS_KEY_ID="$GARAGE_KEY_ID"
		export AWS_SECRET_ACCESS_KEY="$GARAGE_SECRET_KEY"

		NODE_ID=$(docker compose -f "$COMPOSE_FILE" exec -T garage /garage status 2>/dev/null |
			awk '/HEALTHY NODES/{f=2; next} f==2{f=1; next} f==1 && NF{print $1; exit}')
		log "assigning layout to node: $NODE_ID"
		docker compose -f "$COMPOSE_FILE" exec -T garage /garage layout assign -z dc1 -c 5G "$NODE_ID"
		docker compose -f "$COMPOSE_FILE" exec -T garage /garage layout apply --version 1

		log "importing access key"
		docker compose -f "$COMPOSE_FILE" exec -T garage /garage key import --yes -n kanae "$GARAGE_KEY_ID" "$GARAGE_SECRET_KEY"

		log "creating private bucket + granting access"
		docker compose -f "$COMPOSE_FILE" exec -T garage /garage bucket create "$GARAGE_BUCKET"
		docker compose -f "$COMPOSE_FILE" exec -T garage /garage bucket allow --read --write --owner "$GARAGE_BUCKET" --key "$GARAGE_KEY_ID"

		log "setting private bucket CORS policy"
		uvx --from=awscli aws s3api put-bucket-cors \
			--endpoint-url "$GARAGE_URL" \
			--bucket "$GARAGE_BUCKET" \
			--cors-configuration '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","PUT","HEAD"],"AllowedHeaders":["*"],"MaxAgeSeconds":3600}]}' \
			--region garage

		log "setting bucket lifecycle (abort stale multipart after 1 day)"
		uvx --from=awscli aws s3api put-bucket-lifecycle-configuration \
			--endpoint-url "$GARAGE_URL" \
			--bucket "$GARAGE_BUCKET" \
			--lifecycle-configuration '{"Rules":[{"ID":"abort-stale-multipart","Status":"Enabled","Filter":{"Prefix":"media/"},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}' \
			--region garage

		log "creating public bucket for thumbnails"
		docker compose -f "$COMPOSE_FILE" exec -T garage /garage bucket create "$GARAGE_PUBLIC_BUCKET"
		docker compose -f "$COMPOSE_FILE" exec -T garage /garage bucket allow --read --write --owner "$GARAGE_PUBLIC_BUCKET" --key "$GARAGE_KEY_ID"
		docker compose -f "$COMPOSE_FILE" exec -T garage /garage bucket website --allow "$GARAGE_PUBLIC_BUCKET"

		log "setting public bucket CORS policy"
		uvx --from=awscli aws s3api put-bucket-cors \
			--endpoint-url "$GARAGE_URL" \
			--bucket "$GARAGE_PUBLIC_BUCKET" \
			--cors-configuration '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","HEAD"],"AllowedHeaders":["*"],"MaxAgeSeconds":86400}]}' \
			--region garage
	fi
) &
_garage_pid=$!

(
	### 6. Ory bootstrap — identities, members rows, Keto role tuples, IDs into vars.env.

	# shellcheck source=/dev/null
	source "$HURL_VARS"

	# shellcheck source=/dev/null
	source "$ENV_FILE"

	declare -A ROLE_TO_EMAIL_VAR=(
		[admin]=ADMIN_EMAIL
		[manager]=MANAGER_EMAIL
		[leads]=LEADS_EMAIL
		[member]=MEMBER_EMAIL
	)
	declare -A IDS=()
	ROLE_ORDER=(admin manager leads member)

	create_or_lookup_identity() {
		local role="$1" email="$2" body resp code
		body=$(jq -n \
			--arg email "$email" --arg name "$role" --arg pw "$PASSWORD" '
		{
		  schema_id: "default",
		  state: "active",
		  traits: { email: $email, name: $name, display_name: $name },
		  credentials: { password: { config: { password: $pw } } },
		  verifiable_addresses: [
		    { value: $email, verified: true, via: "email", status: "completed" }
		  ]
		}')

		resp=$(curl -sS -w '\n%{http_code}' \
			-H 'Accept: application/json' \
			-H 'Content-Type: application/json' \
			-X POST "$KRATOS_ADMIN_URL/admin/identities" \
			-d "$body")
		code="${resp##*$'\n'}"
		body="${resp%$'\n'*}"

		case "$code" in
		201)
			jq -r '.id' <<<"$body"
			;;
		409)
			curl -fsS -H 'Accept: application/json' \
				"$KRATOS_ADMIN_URL/admin/identities?credentials_identifier=$email" |
				jq -r '.[0].id'
			;;
		*)
			printf 'kratos POST /admin/identities failed (%s): %s\n' "$code" "$body" >&2
			exit 1
			;;
		esac
	}

	log "creating identities via Kratos admin API"
	for role in "${ROLE_ORDER[@]}"; do
		email_var="${ROLE_TO_EMAIL_VAR[$role]}"
		email="${!email_var}"
		id="$(create_or_lookup_identity "$role" "$email")"
		IDS[$role]="$id"
		printf '    %-8s  %s  (%s)\n' "$role" "$id" "$email"
	done

	log "upserting matching members rows (admin-create bypasses the registration webhook)"
	for role in "${ROLE_ORDER[@]}"; do
		email_var="${ROLE_TO_EMAIL_VAR[$role]}"
		email="${!email_var}"
		id="${IDS[$role]}"
		docker compose -f "$COMPOSE_FILE" exec -T database \
			psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" -v ON_ERROR_STOP=1 -q -c \
			"INSERT INTO members (id, name, display_name, email)
		 VALUES ('$id', '$role', '$role', '$email')
		 ON CONFLICT (id) DO UPDATE
		   SET name = EXCLUDED.name,
		       display_name = EXCLUDED.display_name,
		       email = EXCLUDED.email;" >/dev/null
	done

	log "writing Keto Role:* tuples for admin / manager / leads"
	for role in admin manager leads; do
		id="${IDS[$role]}"
		body=$(jq -n --arg ns Role --arg obj "$role" --arg rel member --arg subj "$id" '
		{ namespace: $ns, object: $obj, relation: $rel, subject_id: $subj }')
		curl -fsS \
			-H 'Accept: application/json' \
			-H 'Content-Type: application/json' \
			-X PUT "$KETO_WRITE_URL/admin/relation-tuples" \
			-d "$body" \
			>/dev/null
	done

	log "writing secrets (password + identity UUIDs) to $HURL_SECRETS_FILE"
	{
		printf 'PASSWORD=%s\n' "$PASSWORD"
		printf 'ADMIN_ID=%s\n' "${IDS[admin]}"
		printf 'MANAGER_ID=%s\n' "${IDS[manager]}"
		printf 'LEADS_ID=%s\n' "${IDS[leads]}"
		printf 'MEMBER_ID=%s\n' "${IDS[member]}"
	} >"$HURL_SECRETS_FILE"
) &
_ory_pid=$!

_ok=1
wait "$_garage_pid" || {
	printf '[garage] setup failed\n' >&2
	_ok=0
}
wait "$_ory_pid" || {
	printf '[ory]    bootstrap failed\n' >&2
	_ok=0
}
[[ "$_ok" -eq 1 ]] || exit 1

log "integration-test stack is ready."
log "  - hurl:     hurl --test --variables-file $HURL_VARS --secrets-file $HURL_SECRETS_FILE tests/integration/scenarios/*.hurl"
