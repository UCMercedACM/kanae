#!/usr/bin/env bash
# Note: this is written by Claude Opus 4.7, but I'm leaving it here as it's useful for testing purposes
#
# End-to-end test for the media routes added in routes/projects.py:
#   POST   /projects/{id}/media/upload    (presign or dedup)
#   POST   /projects/{id}/media/commit    (finalize)
#   GET    /projects/{id}/media           (list)
#   PUT    /projects/{id}/media/positions (reorder)
#   DELETE /projects/{id}/media/{hash}    (detach)
#
# and for the thumbnail staging flow on both resources:
#   POST   /projects/{id}/thumbnail/upload + /commit
#   POST   /events/{id}/thumbnail/upload   + /commit
#
# Reuses the registration + role + project setup from test-flow.sh and then
# pushes every file in ./test-images through the full upload flow — single
# PUT for files ≤ 16 MB, multipart for anything larger — plus a set of
# negative cases for the validation guards.
#
# The thumbnail half (steps 29+) covers both entry branches: the project run
# starts from a reaped hash and therefore presigns + PUTs, while the event run
# reuses that now-known hash and takes the dedup branch. Both converge on
# commit, which is where the pyvips encode and the thumbnail_hash swap happen.
#
# Run after `docker compose up -d`. Garage must be initialized too
# (`mise run garage:setup`). Requires: curl, jq, docker, uvx (mise),
# python3 (stdlib only — used for chunk slicing + per-part PUTs).

set -euo pipefail

# ── locate ourselves ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
while [[ "$PROJECT_ROOT" != "/" && ! -f "$PROJECT_ROOT/pyproject.toml" ]]; do
	PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done
if [[ ! -f "$PROJECT_ROOT/pyproject.toml" ]]; then
	printf '\033[0;31m✗\033[0m could not locate project root from %s\n' "$SCRIPT_DIR" >&2
	exit 1
fi
cd "$PROJECT_ROOT"

IMAGES_DIR="$PROJECT_ROOT/test-images"
SINGLE_PUT_MAX=$((16 * 1024 * 1024)) # mirrors _SINGLE_PUT_MAX in projects.py

# ── config ────────────────────────────────────────────────────────────────────
KRATOS_PUBLIC=${KRATOS_PUBLIC:-http://localhost:4433}
KETO_WRITE=${KETO_WRITE:-http://localhost:4467}
KANAE=${KANAE:-http://localhost:8000}
DB_CONTAINER=${DB_CONTAINER:-kanae_postgres}
VALKEY_CONTAINER=${VALKEY_CONTAINER:-kanae_valkey}
DB_NAME=${DB_NAME:-kanae}
DB_USER=${DB_USER:-postgres}

COOKIES="$(mktemp -t kanae-images-cookies.XXXXXX)"

# Presigned upload URLs are signed by kanae (in-container) against the internal
# S3 host "garage:3900", which the host running this script can't resolve — a
# bare PUT there fails with curl code 000. Rather than editing /etc/hosts, point
# just this script's subprocesses at the published port via a private glibc
# HOSTALIASES file: getaddrinfo redirects the single-label host "garage" to
# localhost for both curl (single PUT) and Python's urllib (multipart), while the
# Host header — and therefore the SigV4 signature — stays "garage:3900".
HOSTALIASES_FILE="$(mktemp -t kanae-images-hostaliases.XXXXXX)"
printf 'garage localhost\n' >"$HOSTALIASES_FILE"
export HOSTALIASES="$HOSTALIASES_FILE"

trap 'rm -f "$COOKIES" "$HOSTALIASES_FILE"' EXIT

EMAIL="images-$(date +%s)-$$@ucmerced.edu"
PASSWORD="correct-horse-battery-staple-2026"
NAME="Images Test"

# ── output helpers ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YEL=$'\033[0;33m'
BLU=$'\033[0;34m'
RST=$'\033[0m'

H_CONTENT_TYPE="Content-Type: application/json"
JQ_HASH='.hash // empty'
JQ_URL='.url // empty'

# curl --write-out format selecting just the response status.
CURL_HTTP_CODE='%{http_code}'

step() {
	local msg="$1"
	printf "\n${BLU}━━ %s ━━${RST}\n" "$msg"
}
ok() {
	local msg="$1"
	printf "${GRN}✓${RST} %s\n" "$msg"
}
warn() {
	local msg="$1"
	printf "${YEL}⚠${RST} %s\n" "$msg"
}
fail() {
	local msg="$1"
	printf "${RED}✗${RST} %s\n" "$msg" >&2
	exit 1
}
# One indented continuation line, e.g. a URL printed under its label. A helper
# rather than a format-string constant: `printf "$FMT"` trips SC2059.
detail() {
	local msg="$1"
	printf '    %s\n' "$msg"
}

require() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1 || fail "missing required tool: $cmd"
}

assert_http() {
	# assert_http <expected-status> <method> <url> [curl args...]
	local expected="$1" method="$2" url="$3"
	shift 3
	local actual
	actual="$(curl -s -o /dev/null -w "$CURL_HTTP_CODE" -X "$method" "$url" "$@")"
	if [[ "$actual" != "$expected" ]]; then
		fail "expected HTTP $expected from $method $url, got $actual"
	fi
	ok "$method $url -> $actual"
}

# Compute a file's BLAKE3 hex digest. Uses uvx so we don't depend on the
# project's venv being active.
blake3_hash() {
	local file="$1"
	uvx --quiet --from blake3 python -c '
import sys
from blake3 import blake3
with open(sys.argv[1], "rb") as f:
    print(blake3(f.read()).hexdigest())
' "$file"
}

# Derive a content-type from a file extension. Returns 1 if unrecognized.
content_type_for() {
	local file="$1"
	local ext="${file##*.}"
	case "${ext,,}" in
		gif) echo "image/gif" ;;
		png) echo "image/png" ;;
		jpg | jpeg) echo "image/jpeg" ;;
		webp) echo "image/webp" ;;
		mp4) echo "video/mp4" ;;
		webm) echo "video/webm" ;;
		mov) echo "video/quicktime" ;;
		*) return 1 ;;
	esac
}

# ── 0. preflight ──────────────────────────────────────────────────────────────
step "0. preflight"
require curl
require jq
require docker
require uvx
require python3

[[ -d "$IMAGES_DIR" ]] || fail "test-images directory missing: $IMAGES_DIR"

MEDIA_FILES=()
while IFS= read -r -d '' file; do
	MEDIA_FILES+=("$file")
done < <(find "$IMAGES_DIR" -maxdepth 1 -type f \
	\( -iname '*.gif' -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
	-o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mov' \) \
	-print0 | sort -z)

[[ ${#MEDIA_FILES[@]} -ge 1 ]] || fail "no supported media files in $IMAGES_DIR"
ok "found ${#MEDIA_FILES[@]} media files"

# /media/upload is billed per file, and steps 8-12 spend 5 more on the same
# key. The limiter keys on the request path (key_style="url") and each run
# creates a fresh project, so nothing carries over between runs — but a large
# enough directory exhausts the budget inside a single run, which surfaces as a
# confusing 429 on whichever negative case happens to land last.
UPLOAD_RATE_LIMIT=60 # mirrors @router.limiter.limit on upload_media
if ((${#MEDIA_FILES[@]} + 5 > UPLOAD_RATE_LIMIT)); then
	warn "${#MEDIA_FILES[@]} files + 5 negative cases exceeds the ${UPLOAD_RATE_LIMIT}/minute limit on /media/upload"
	warn "expect 429s — trim $IMAGES_DIR or raise the limit on upload_media"
fi

curl -sf "$KRATOS_PUBLIC/health/ready" >/dev/null || fail "kratos not ready at $KRATOS_PUBLIC"
ok "kratos ready"
curl -sf -o /dev/null -w '' "$KANAE/" || fail "kanae not responding at $KANAE"
ok "kanae responding"

# ── 1. register user via Kratos ───────────────────────────────────────────────
step "1. register $EMAIL"

FLOW=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "Accept: application/json" \
	"$KRATOS_PUBLIC/self-service/registration/browser" \
	| jq -r .id)
[[ -n "$FLOW" && "$FLOW" != "null" ]] || fail "no registration flow id"

CSRF=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "Accept: application/json" \
	"$KRATOS_PUBLIC/self-service/registration/flows?id=$FLOW" \
	| jq -r '.ui.nodes[] | select(.attributes.name=="csrf_token") | .attributes.value')

REG_RESP=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-H "Accept: application/json" \
	-X POST "$KRATOS_PUBLIC/self-service/registration?flow=$FLOW" \
	-d '{
    "method": "password",
    "csrf_token": "'"$CSRF"'",
    "password":   "'"$PASSWORD"'",
    "traits": { "email": "'"$EMAIL"'", "name": "'"$NAME"'" }
  }')

IDENTITY_ID=$(jq -r '.identity.id // empty' <<<"$REG_RESP")
[[ -n "$IDENTITY_ID" ]] \
	|| fail "registration failed: $(jq -c '.ui.messages // .error // .' <<<"$REG_RESP")"
ok "identity id: $IDENTITY_ID"

# ── 2. wait for members-table webhook sync ────────────────────────────────────
step "2. wait for members table sync"

ROW=""
for _ in 1 2 3 4 5; do
	ROW=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tA \
		-c "SELECT 1 FROM members WHERE id = '$IDENTITY_ID';" \
		2>/dev/null || true)
	[[ -n "$ROW" ]] && break
	sleep 1
done
[[ -n "$ROW" ]] || fail "members row never appeared — check kanae and kratos webhook logs"
ok "members row synced"

# ── 3-5. role, project, ownership ─────────────────────────────────────────────
step "3. grant manager role"

curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
	-H "$H_CONTENT_TYPE" \
	-d '{
    "namespace":  "Role",
    "object":     "manager",
    "relation":   "member",
    "subject_id": "'"$IDENTITY_ID"'"
  }' >/dev/null
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
ok "Role:manager#member tuple written, cache flushed"

step "4. create project"

PROJ_BODY='{
  "name": "Media Test Project",
  "description": "for media route tests",
  "link": "https://example.com",
  "type": "independent",
  "active": true,
  "founded_at": "2026-01-01T00:00:00Z"
}'
CREATE_RESP=$(curl -s -X POST "$KANAE/projects/create" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "$PROJ_BODY")
PROJECT_ID=$(jq -r '.id // empty' <<<"$CREATE_RESP")
[[ -n "$PROJECT_ID" ]] || fail "project create failed: $CREATE_RESP"
ok "project id: $PROJECT_ID"

step "5. grant Project owners"

curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
	-H "$H_CONTENT_TYPE" \
	-d '{
    "namespace":  "Project",
    "object":     "'"$PROJECT_ID"'",
    "relation":   "owners",
    "subject_id": "'"$IDENTITY_ID"'"
  }' >/dev/null
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
ok "owner tuple written, cache flushed"

# ── upload helpers ────────────────────────────────────────────────────────────

# Single-PUT path: declare, presign, PUT bytes, commit.
upload_single() {
	local file="$1" hash="$2" size="$3" content_type="$4"

	local upload_resp
	upload_resp=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/media/upload" \
		-b "$COOKIES" \
		-H "$H_CONTENT_TYPE" \
		-d "{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size}")

	# Dedup path: response is a MediaRecord (has a `hash` field). Nothing to PUT.
	if [[ "$(jq -r 'has("hash")' <<<"$upload_resp")" == "true" ]]; then
		return 0
	fi

	local url
	url=$(jq -r "$JQ_URL" <<<"$upload_resp")
	[[ -n "$url" ]] || fail "no presigned url in upload response: $upload_resp"

	local put_code
	put_code=$(curl -s -o /dev/null -w "$CURL_HTTP_CODE" \
		-X PUT "$url" \
		-H "Content-Type: $content_type" \
		--data-binary "@$file")
	[[ "$put_code" =~ ^2[0-9][0-9]$ ]] \
		|| fail "PUT to presigned url returned $put_code (expected 2xx)"

	local commit_resp commit_hash
	commit_resp=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/media/commit" \
		-b "$COOKIES" \
		-H "$H_CONTENT_TYPE" \
		-d "{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size}")
	commit_hash=$(jq -r "$JQ_HASH" <<<"$commit_resp")
	[[ "$commit_hash" == "$hash" ]] \
		|| fail "commit response did not echo hash: $commit_resp"
}

# Multipart path: init, slice + PUT each chunk via python3 stdlib (clean
# byte-range reads, ETag capture), commit with collected ETags.
upload_multipart() {
	local file="$1" hash="$2" size="$3" content_type="$4"

	local upload_resp
	upload_resp=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/media/upload" \
		-b "$COOKIES" \
		-H "$H_CONTENT_TYPE" \
		-d "{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size}")

	# Dedup path: response is a MediaRecord. Nothing to upload.
	if [[ "$(jq -r 'has("hash")' <<<"$upload_resp")" == "true" ]]; then
		return 0
	fi

	local upload_id chunks
	upload_id=$(jq -r '.upload_id // empty' <<<"$upload_resp")
	chunks=$(jq -c '.chunks // empty' <<<"$upload_resp")
	[[ -n "$upload_id" && -n "$chunks" && "$chunks" != "null" ]] \
		|| fail "no upload_id/chunks in multipart response: $upload_resp"

	# PUT each chunk, capture ETags. Sequential file.read() walks the bytes
	# in chunk order, so no seeking math is needed.
	local completed
	completed=$(printf '%s' "$chunks" | python3 -c '
import sys, json
from urllib.request import Request, urlopen
from urllib.error import HTTPError

file_path = sys.argv[1]
chunks = json.load(sys.stdin)
results = []
with open(file_path, "rb") as f:
    for chunk in chunks:
        idx = chunk["index"]
        chunk_size = chunk["size"]
        data = f.read(chunk_size)
        if len(data) != chunk_size:
            sys.stderr.write(f"chunk {idx}: read {len(data)} bytes, expected {chunk_size}\n")
            sys.exit(1)
        req = Request(chunk["url"], data=data, method="PUT")
        try:
            with urlopen(req) as resp:
                # ETags are opaque tokens: pass them back to complete_multipart
                # verbatim, including any surrounding quotes Garage emits.
                etag = resp.headers.get("etag", "")
        except HTTPError as e:
            sys.stderr.write(f"chunk {idx}: HTTP {e.code} {e.reason}\n")
            sys.exit(1)
        if not etag:
            sys.stderr.write(f"chunk {idx}: no etag in response\n")
            sys.exit(1)
        results.append({"number": idx, "etag": etag})
print(json.dumps(results))
' "$file") || fail "multipart PUT failed for $file"

	local commit_resp commit_hash
	commit_resp=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/media/commit" \
		-b "$COOKIES" \
		-H "$H_CONTENT_TYPE" \
		-d "{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size,\"upload_id\":\"$upload_id\",\"chunks\":$completed}")
	commit_hash=$(jq -r "$JQ_HASH" <<<"$commit_resp")
	[[ "$commit_hash" == "$hash" ]] \
		|| fail "multipart commit response did not echo hash: $commit_resp"
}

# Dispatcher. Prints "<hash> <mode>" on success.
upload_file() {
	local file="$1"
	local hash size content_type mode
	hash="$(blake3_hash "$file")"
	size="$(stat -c %s "$file")"
	content_type="$(content_type_for "$file")" \
		|| fail "unsupported file extension: $file"

	if ((size <= SINGLE_PUT_MAX)); then
		upload_single "$file" "$hash" "$size" "$content_type"
		mode="single"
	else
		upload_multipart "$file" "$hash" "$size" "$content_type"
		mode="multipart"
	fi
	printf '%s %s\n' "$hash" "$mode"
}

# ── 6. upload every media file via the appropriate flow ───────────────────────
step "6. upload all media (single PUT or multipart, by size)"

HASHES=()
for file in "${MEDIA_FILES[@]}"; do
	size=$(stat -c %s "$file")
	size_human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B")
	result=$(upload_file "$file")
	hash="${result% *}"
	mode="${result#* }"
	HASHES+=("$hash")
	ok "$(basename "$file") ($size_human, $mode) -> $hash"
done

# ── 7. list returns every uploaded media ──────────────────────────────────────
step "7. GET /media returns ${#HASHES[@]} records"

LIST_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID/media")
LIST_COUNT=$(jq 'length' <<<"$LIST_RESP")
[[ "$LIST_COUNT" -eq "${#HASHES[@]}" ]] \
	|| fail "expected ${#HASHES[@]} media rows, got $LIST_COUNT: $LIST_RESP"
ok "list returned $LIST_COUNT items"

ok "presigned GET URLs (copy to verify the bytes landed):"
for i in "${!MEDIA_FILES[@]}"; do
	hash="${HASHES[$i]}"
	file="${MEDIA_FILES[$i]}"
	url=$(jq -r --arg h "$hash" '.[] | select(.hash == $h) | .url // empty' <<<"$LIST_RESP")
	[[ -n "$url" ]] || fail "hash $hash missing from list or has no URL"
	printf "    %s\n      %s\n" "$(basename "$file")" "$url"
done

# ── 8. dedup: re-upload first file's hash -> existing MediaRecord ─────────────
step "8. POST /media/upload with existing hash -> returns MediaRecord (no presign)"

FIRST_HASH="${HASHES[0]}"
FIRST_FILE="${MEDIA_FILES[0]}"
FIRST_SIZE=$(stat -c %s "$FIRST_FILE")
FIRST_CT=$(content_type_for "$FIRST_FILE")
DEDUP_RESP=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/media/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "{\"hash\":\"$FIRST_HASH\",\"content_type\":\"$FIRST_CT\",\"size\":$FIRST_SIZE}")
DEDUP_HASH=$(jq -r "$JQ_HASH" <<<"$DEDUP_RESP")
[[ "$DEDUP_HASH" == "$FIRST_HASH" ]] \
	|| fail "dedup did not return existing record: $DEDUP_RESP"
ok "dedup returned existing record"

# ── 9. negative: invalid content-type -> 415 ──────────────────────────────────
step "9. POST /media/upload with disallowed content-type -> 415"

assert_http 415 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"application/pdf","size":1024}'

# ── 10. negative: zero size -> 400 ────────────────────────────────────────────
step "10. POST /media/upload with size=0 -> 400"

assert_http 400 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"image/gif","size":0}'

# ── 11. negative: oversized image -> 413 ──────────────────────────────────────
step "11. POST /media/upload with image size > 32 MB -> 413"

assert_http 413 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"image/gif","size":40000000}'

# ── 12. negative: oversized video -> 413 ──────────────────────────────────────
step "12. POST /media/upload with video size > 2 GB -> 413"

assert_http 413 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"video/mp4","size":3000000000}'

# ── 13. reorder: reverse the list ─────────────────────────────────────────────
step "13. PUT /media/positions reverses the order"

REVERSED=$(printf '%s\n' "${HASHES[@]}" | tac | jq -R . | jq -sc .)
REORDER_RESP=$(curl -s -X PUT "$KANAE/projects/$PROJECT_ID/media/positions" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "{\"hashes\":$REVERSED}")
REORDER_MSG=$(jq -r '.message // empty' <<<"$REORDER_RESP")
[[ -n "$REORDER_MSG" ]] || fail "reorder failed: $REORDER_RESP"
ok "reorder accepted (message: $REORDER_MSG)"

# ── 14. verify reorder ────────────────────────────────────────────────────────
step "14. GET /media reflects new order"

LIST_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID/media")
ACTUAL_FIRST=$(jq -r '.[0].hash // empty' <<<"$LIST_RESP")
EXPECTED_FIRST="${HASHES[-1]}"
[[ "$ACTUAL_FIRST" == "$EXPECTED_FIRST" ]] \
	|| fail "first item is $ACTUAL_FIRST, expected $EXPECTED_FIRST (reversed)"
ok "first item is now the previously-last upload"

# ── 15. negative: reorder with unknown hash -> 404 ────────────────────────────
step "15. PUT /media/positions with hash not in project -> 404"

assert_http 404 PUT "$KANAE/projects/$PROJECT_ID/media/positions" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hashes":["0000000000000000000000000000000000000000000000000000000000000000"]}'

# ── 16. delete one media ──────────────────────────────────────────────────────
step "16. DELETE /media/<hash> removes last uploaded hash"

TO_DELETE="${HASHES[-1]}"
assert_http 200 DELETE "$KANAE/projects/$PROJECT_ID/media/$TO_DELETE" -b "$COOKIES"

# ── 17. list reflects deletion ────────────────────────────────────────────────
step "17. GET /media reflects deletion"

LIST_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID/media")
LIST_COUNT=$(jq 'length' <<<"$LIST_RESP")
EXPECTED=$((${#HASHES[@]} - 1))
[[ "$LIST_COUNT" -eq "$EXPECTED" ]] \
	|| fail "expected $EXPECTED media after delete, got $LIST_COUNT"
ok "list returned $LIST_COUNT items"

jq -e --arg h "$TO_DELETE" 'all(.[]; .hash != $h)' <<<"$LIST_RESP" >/dev/null \
	|| fail "deleted hash $TO_DELETE still present in list"
ok "deleted hash is gone from list"

# ── 18. negative: re-delete same hash -> 404 ──────────────────────────────────
step "18. DELETE /media/<hash> for already-detached hash -> 404"

assert_http 404 DELETE "$KANAE/projects/$PROJECT_ID/media/$TO_DELETE" -b "$COOKIES"

# ── 19. final URL list (post-delete) ──────────────────────────────────────────
step "19. surviving media — copy any of these URLs to verify they still work"

FINAL_LIST=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID/media")
FINAL_COUNT=$(jq 'length' <<<"$FINAL_LIST")
printf "    %d files left in project\n" "$FINAL_COUNT"
for i in "${!MEDIA_FILES[@]}"; do
	hash="${HASHES[$i]}"
	file="${MEDIA_FILES[$i]}"
	url=$(jq -r --arg h "$hash" '.[] | select(.hash == $h) | .url // empty' <<<"$FINAL_LIST")
	if [[ -n "$url" ]]; then
		printf "    %s\n      %s\n" "$(basename "$file")" "$url"
	fi
done

# ── 20. set thumbnail using first surviving image ─────────────────────────────
step "20. POST /thumbnail with first surviving image hash"

THUMB_SRC_HASH=""
THUMB_SRC_CT=""
THUMB_SRC_FILE=""
for i in "${!MEDIA_FILES[@]}"; do
	candidate="${HASHES[$i]}"
	[[ "$candidate" == "$TO_DELETE" ]] && continue
	ct="$(content_type_for "${MEDIA_FILES[$i]}")"
	if [[ "$ct" == image/* ]]; then
		THUMB_SRC_HASH="$candidate"
		THUMB_SRC_CT="$ct"
		THUMB_SRC_FILE="${MEDIA_FILES[$i]}"
		break
	fi
done
[[ -n "$THUMB_SRC_HASH" ]] || fail "no surviving image in project to use as thumbnail source"
ok "using $(basename "$THUMB_SRC_FILE") ($THUMB_SRC_CT) — $THUMB_SRC_HASH"

THUMB_RESP=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/thumbnail" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "{\"hash\":\"$THUMB_SRC_HASH\",\"content_type\":\"$THUMB_SRC_CT\"}")
THUMB_MSG=$(jq -r '.message // empty' <<<"$THUMB_RESP")
[[ -n "$THUMB_MSG" ]] || fail "thumbnail set failed: $THUMB_RESP"
ok "thumbnail processed and recorded (message: $THUMB_MSG)"

# ── 21. GET /projects/{id} returns thumbnail object ───────────────────────────
step "21. GET /projects/{id} returns thumbnail {hash, url}"

PROJ_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID")
THUMB_OBJ=$(jq -c '.thumbnail' <<<"$PROJ_RESP")
[[ -n "$THUMB_OBJ" && "$THUMB_OBJ" != "null" ]] \
	|| fail "thumbnail missing from project response: $PROJ_RESP"

THUMB_HASH=$(jq -r "$JQ_HASH" <<<"$THUMB_OBJ")
THUMB_URL=$(jq -r "$JQ_URL" <<<"$THUMB_OBJ")
[[ -n "$THUMB_HASH" && -n "$THUMB_URL" ]] \
	|| fail "thumbnail object missing hash or url: $THUMB_OBJ"
ok "thumbnail.hash = $THUMB_HASH"
detail "$THUMB_URL"

# ── 22. thumbnail URL is anonymously reachable and returns webp ───────────────
step "22. GET <thumbnail_url> returns 200 + image/webp"

THUMB_CHECK=$(curl -s -o /dev/null -w "$CURL_HTTP_CODE %{content_type}" "$THUMB_URL")
THUMB_STATUS="${THUMB_CHECK%% *}"
THUMB_TYPE="${THUMB_CHECK#* }"
if [[ "$THUMB_STATUS" == "200" && "$THUMB_TYPE" == image/webp* ]]; then
	ok "thumbnail URL serves bytes anonymously ($THUMB_STATUS, $THUMB_TYPE)"
else
	warn "thumbnail URL did not return 200 + image/webp (status=$THUMB_STATUS, type=$THUMB_TYPE)"
	warn "verify mise run garage:setup created the public bucket with website mode,"
	warn "and that storage.public.url resolves from this host"
fi

# ── 23. list_projects surfaces the same thumbnail ─────────────────────────────
step "23. GET /projects shows thumbnail for this project"

LIST_PROJ_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects?active=true")
LIST_THUMB=$(jq -c --arg id "$PROJECT_ID" '.data[] | select(.id == $id) | .thumbnail' <<<"$LIST_PROJ_RESP")
[[ -n "$LIST_THUMB" && "$LIST_THUMB" != "null" ]] \
	|| fail "thumbnail missing from /projects listing: $LIST_PROJ_RESP"

LIST_THUMB_HASH=$(jq -r '.hash' <<<"$LIST_THUMB")
LIST_THUMB_URL=$(jq -r '.url' <<<"$LIST_THUMB")
[[ "$LIST_THUMB_HASH" == "$THUMB_HASH" ]] \
	|| fail "list_projects thumbnail hash $LIST_THUMB_HASH != get_project's $THUMB_HASH"
[[ "$LIST_THUMB_URL" == "$THUMB_URL" ]] \
	|| fail "list_projects thumbnail url differs from get_project's"
ok "list_projects matches get_project for thumbnail"

# ── 24. replace thumbnail with a different image, verify hash changes ─────────
step "24. POST /thumbnail with a different image replaces the prior one"

THUMB_ALT_HASH=""
THUMB_ALT_CT=""
THUMB_ALT_FILE=""
for i in "${!MEDIA_FILES[@]}"; do
	candidate="${HASHES[$i]}"
	[[ "$candidate" == "$TO_DELETE" || "$candidate" == "$THUMB_SRC_HASH" ]] && continue
	ct="$(content_type_for "${MEDIA_FILES[$i]}")"
	if [[ "$ct" == image/* ]]; then
		THUMB_ALT_HASH="$candidate"
		THUMB_ALT_CT="$ct"
		THUMB_ALT_FILE="${MEDIA_FILES[$i]}"
		break
	fi
done

if [[ -z "$THUMB_ALT_HASH" ]]; then
	warn "no second image available; skipping replacement test"
else
	ok "replacing with $(basename "$THUMB_ALT_FILE") — $THUMB_ALT_HASH"
	curl -sf -X POST "$KANAE/projects/$PROJECT_ID/thumbnail" \
		-b "$COOKIES" \
		-H "$H_CONTENT_TYPE" \
		-d "{\"hash\":\"$THUMB_ALT_HASH\",\"content_type\":\"$THUMB_ALT_CT\"}" >/dev/null \
		|| fail "replacement POST failed"

	NEW_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID")
	NEW_HASH=$(jq -r '.thumbnail.hash // empty' <<<"$NEW_RESP")
	NEW_URL=$(jq -r '.thumbnail.url // empty' <<<"$NEW_RESP")
	[[ -n "$NEW_HASH" && "$NEW_HASH" != "$THUMB_HASH" ]] \
		|| fail "thumbnail hash did not change after replacement (still $NEW_HASH)"
	ok "thumbnail hash updated: $THUMB_HASH -> $NEW_HASH"
fi

# ── 25. negative: video content-type rejected ─────────────────────────────────
step "25. POST /thumbnail with video content-type -> 400"

assert_http 400 POST "$KANAE/projects/$PROJECT_ID/thumbnail" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"0000000000000000000000000000000000000000000000000000000000000000","content_type":"video/mp4"}'

# ── 26. thumbnail URLs — open these in a browser to verify ────────────────────
step "26. thumbnail URLs for manual verification"

printf "    initial thumbnail (%s):\n      %s\n" "$THUMB_HASH" "$THUMB_URL"
if [[ -n "${NEW_URL:-}" ]]; then
	printf "    current thumbnail (%s):\n      %s\n" "$NEW_HASH" "$NEW_URL"
fi

# ── 27. DELETE /thumbnail clears the project thumbnail ────────────────────────
step "27. DELETE /projects/{id}/thumbnail removes the thumbnail"

CURRENT_URL="${NEW_URL:-$THUMB_URL}"

assert_http 200 DELETE "$KANAE/projects/$PROJECT_ID/thumbnail" -b "$COOKIES"

POST_DELETE=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID")
POST_DELETE_THUMB=$(jq -r '.thumbnail' <<<"$POST_DELETE")
[[ "$POST_DELETE_THUMB" == "null" ]] \
	|| fail "thumbnail not cleared from project: $POST_DELETE_THUMB"
ok "project.thumbnail is null after DELETE"

DEL_CHECK=$(curl -s -o /dev/null -w "$CURL_HTTP_CODE" "$CURRENT_URL")
if [[ "$DEL_CHECK" == "404" ]]; then
	ok "thumbnail URL now returns 404 anonymously"
else
	warn "expected 404 for removed thumbnail URL, got $DEL_CHECK ($CURRENT_URL)"
fi

# ── 28. DELETE is idempotent — second call still returns 200 ──────────────────
step "28. DELETE /projects/{id}/thumbnail is idempotent"

assert_http 200 DELETE "$KANAE/projects/$PROJECT_ID/thumbnail" -b "$COOKIES"

# ── thumbnail upload/commit helpers ───────────────────────────────────────────

# Run the two-step thumbnail staging flow against a resource base URL
# ("$KANAE/projects/<id>" or "$KANAE/events/<id>"):
#
#   POST <base>/thumbnail/upload  → presigned PUT url, or the existing record
#   PUT  <presigned url>          → only on the presign branch
#   POST <base>/thumbnail/commit  → processes the WebP and attaches it
#
# Prints "<mode> <thumbnail_hash> <thumbnail_url>" on success, where mode is
# "fresh" (presigned, bytes PUT) or "dedup" (hash already known, PUT skipped).
#
# Everything the caller needs goes to stdout: callers invoke this inside a
# command substitution, which runs the function in a subshell, so a global
# assigned here would be discarded on return. Nothing else may be printed.
thumbnail_flow() {
	local base="$1" file="$2" hash="$3" size="$4" content_type="$5"
	local body="{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size}"
	local mode

	local upload_resp
	upload_resp=$(curl -s -X POST "$base/thumbnail/upload" \
		-b "$COOKIES" \
		-H "$H_CONTENT_TYPE" \
		-d "$body")

	if [[ "$(jq -r 'has("hash")' <<<"$upload_resp")" == "true" ]]; then
		# Dedup branch: the hash is already in `media`, so the bytes are
		# already in the bucket and there is nothing to PUT.
		mode="dedup"
	else
		mode="fresh"

		local url put_code
		url=$(jq -r "$JQ_URL" <<<"$upload_resp")
		[[ -n "$url" ]] \
			|| fail "no presigned url in thumbnail upload response: $upload_resp"

		put_code=$(curl -s -o /dev/null -w "$CURL_HTTP_CODE" \
			-X PUT "$url" \
			-H "Content-Type: $content_type" \
			--data-binary "@$file")
		[[ "$put_code" =~ ^2[0-9][0-9]$ ]] \
			|| fail "PUT to thumbnail presigned url returned $put_code (expected 2xx)"
	fi

	local commit_resp thumb_hash thumb_url
	commit_resp=$(curl -s -X POST "$base/thumbnail/commit" \
		-b "$COOKIES" \
		-H "$H_CONTENT_TYPE" \
		-d "$body")
	thumb_hash=$(jq -r "$JQ_HASH" <<<"$commit_resp")
	thumb_url=$(jq -r "$JQ_URL" <<<"$commit_resp")
	[[ -n "$thumb_hash" && -n "$thumb_url" ]] \
		|| fail "thumbnail commit failed: $commit_resp"

	# Commit returns the *processed* WebP, not the source that was uploaded,
	# so its digest must differ from the source hash.
	[[ "$thumb_hash" != "$hash" ]] \
		|| fail "commit echoed the source hash instead of the processed WebP digest"

	printf '%s %s %s\n' "$mode" "$thumb_hash" "$thumb_url"
}

# ── 29. detach the thumbnail source so the staging flow starts cold ───────────
step "29. DELETE /media/<hash> reaps the source, making the next upload fresh"

# remove_project_media drops the media row and the S3 object once no
# project_media rows reference the hash, so this hash becomes unknown to both
# the DB and the bucket — which is what forces the presign branch below.
assert_http 200 DELETE "$KANAE/projects/$PROJECT_ID/media/$THUMB_SRC_HASH" -b "$COOKIES"

THUMB_SRC_SIZE=$(stat -c %s "$THUMB_SRC_FILE")

# ── 30. project thumbnail via upload -> PUT -> commit ─────────────────────────
step "30. POST /projects/{id}/thumbnail/upload + /commit (full staging flow)"

FLOW_RESULT=$(thumbnail_flow \
	"$KANAE/projects/$PROJECT_ID" \
	"$THUMB_SRC_FILE" "$THUMB_SRC_HASH" "$THUMB_SRC_SIZE" "$THUMB_SRC_CT")
# `read` with a here-string runs in the current shell, so these persist.
read -r STAGED_MODE STAGED_HASH STAGED_URL <<<"$FLOW_RESULT"

[[ "$STAGED_MODE" == "fresh" ]] \
	|| warn "expected the presign branch after the reap, took '$STAGED_MODE' instead"
ok "$STAGED_MODE flow committed thumbnail $STAGED_HASH"
detail "$STAGED_URL"

# ── 31. the committed thumbnail is the project's thumbnail ────────────────────
step "31. GET /projects/{id} reflects the committed thumbnail"

STAGED_PROJ=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID")
STAGED_PROJ_HASH=$(jq -r '.thumbnail.hash // empty' <<<"$STAGED_PROJ")
[[ "$STAGED_PROJ_HASH" == "$STAGED_HASH" ]] \
	|| fail "project thumbnail is $STAGED_PROJ_HASH, expected $STAGED_HASH"
ok "project.thumbnail.hash matches the commit response"

# The commit re-inserted the source into `media` (which is what lets step 34
# take the dedup branch) but deliberately left project_media alone, so the
# reaped hash must NOT be back in the project's gallery. A thumbnail source is
# not gallery content.
STAGED_LIST=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID/media")
# An `... && fail` one-liner would abort under `set -e` on the passing path, so
# the negative assertion is spelled out as an if.
if jq -e --arg h "$THUMB_SRC_HASH" 'any(.[]; .hash == $h)' <<<"$STAGED_LIST" >/dev/null; then
	fail "commit linked the source into project_media: $STAGED_LIST"
fi
ok "commit left the source out of project_media"

STAGED_CHECK=$(curl -s -o /dev/null -w "$CURL_HTTP_CODE %{content_type}" "$STAGED_URL")
STAGED_STATUS="${STAGED_CHECK%% *}"
STAGED_TYPE="${STAGED_CHECK#* }"
if [[ "$STAGED_STATUS" == "200" && "$STAGED_TYPE" == image/webp* ]]; then
	ok "staged thumbnail URL serves bytes anonymously ($STAGED_STATUS, $STAGED_TYPE)"
else
	warn "staged thumbnail URL did not return 200 + image/webp (status=$STAGED_STATUS, type=$STAGED_TYPE)"
fi

# ── 32. negatives on the project staging routes ───────────────────────────────
step "32. validation guards on /thumbnail/upload"

# The guard matrix runs on the upload route. validate_thumbnail is one shared
# function that all four thumbnail handlers call identically, so re-asserting
# each case against commit buys no coverage — and commit only has 3/minute to
# spend, which this script needs for the real commit above plus the 409 in
# step 37. The commit-specific 404 runs once, on the event route in step 36.

# Video content type → 400, not the 415 that /media/upload answers with. The
# thumbnail validator narrows to images and reports it as a bad request.
assert_http 400 POST "$KANAE/projects/$PROJECT_ID/thumbnail/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"video/mp4","size":1024}'

# Same input, the other validator — 415 here, 400 above.
assert_http 415 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"application/pdf","size":1024}'

assert_http 400 POST "$KANAE/projects/$PROJECT_ID/thumbnail/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"image/png","size":0}'

# Over the 32 MB thumbnail cap.
assert_http 413 POST "$KANAE/projects/$PROJECT_ID/thumbnail/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"image/png","size":33554433}'

# ── 33. create an event to exercise the same flow without a bridge table ──────
step "33. grant leads role and create an event"

curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
	-H "$H_CONTENT_TYPE" \
	-d '{
    "namespace":  "Role",
    "object":     "leads",
    "relation":   "member",
    "subject_id": "'"$IDENTITY_ID"'"
  }' >/dev/null
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
ok "Role:leads#member tuple written, cache flushed"

# `id` is required by the request model (create_events takes a full `Events`)
# but is then dropped via exclude={"id", "creator_id"} — Postgres mints the
# real UUID, and the response carries it. So this value is a placeholder that
# never reaches the database; PROJECT_ID-style reuse of it would be wrong.
# creator_id is optional and comes from the session, so it's omitted.
EVENT_BODY='{
  "id": "00000000-0000-4000-8000-000000000000",
  "name": "Media Test Event",
  "description": "for thumbnail route tests",
  "start_at": "2099-01-01T00:00:00Z",
  "end_at":   "2099-01-01T02:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "America/Los_Angeles"
}'
EVENT_RESP=$(curl -s -X POST "$KANAE/events/create" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "$EVENT_BODY")
EVENT_ID=$(jq -r '.id // empty' <<<"$EVENT_RESP")
[[ -n "$EVENT_ID" ]] || fail "event create failed: $EVENT_RESP"
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
ok "event id: $EVENT_ID"

# ── 34. event thumbnail via upload -> commit (dedup branch) ───────────────────
step "34. POST /events/{id}/thumbnail/upload + /commit"

# The source hash is back in `media` after step 30's commit, so this run takes
# the dedup branch and skips the PUT — the other half of the upload route.
# Events have no media-association table, so nothing is linked either way.
EVENT_FLOW=$(thumbnail_flow \
	"$KANAE/events/$EVENT_ID" \
	"$THUMB_SRC_FILE" "$THUMB_SRC_HASH" "$THUMB_SRC_SIZE" "$THUMB_SRC_CT")
read -r EVENT_MODE EVENT_THUMB_HASH EVENT_THUMB_URL <<<"$EVENT_FLOW"

[[ "$EVENT_MODE" == "dedup" ]] \
	|| warn "expected the dedup branch for a known hash, took '$EVENT_MODE' instead"
ok "$EVENT_MODE flow committed thumbnail $EVENT_THUMB_HASH"
detail "$EVENT_THUMB_URL"

# Same source bytes as the project thumbnail, so the processed WebP is
# content-identical and lands on the same hash.
[[ "$EVENT_THUMB_HASH" == "$STAGED_HASH" ]] \
	|| warn "event thumbnail hash $EVENT_THUMB_HASH differs from the project's $STAGED_HASH for identical source bytes"

# ── 35. the committed thumbnail is the event's thumbnail ──────────────────────
step "35. GET /events/{id} reflects the committed thumbnail"

EVENT_GET=$(curl -s -b "$COOKIES" "$KANAE/events/$EVENT_ID")
EVENT_GET_HASH=$(jq -r '.thumbnail.hash // empty' <<<"$EVENT_GET")
[[ "$EVENT_GET_HASH" == "$EVENT_THUMB_HASH" ]] \
	|| fail "event thumbnail is $EVENT_GET_HASH, expected $EVENT_THUMB_HASH"
ok "event.thumbnail.hash matches the commit response"

# ── 36. negatives on the event staging routes ─────────────────────────────────
step "36. validation guards on the event staging routes"

assert_http 400 POST "$KANAE/events/$EVENT_ID/thumbnail/upload" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"video/mp4","size":1024}'

assert_http 404 POST "$KANAE/events/$EVENT_ID/thumbnail/commit" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"image/png","size":1024}'

# ── 37. commit with a mismatched declared size -> 409 ─────────────────────────
step "37. POST /thumbnail/commit with the wrong size -> 409"

# head reports the real object size, which won't match the inflated declaration.
# Destructive on purpose and therefore last: the route deletes the source
# object from the bucket before answering, so the source can't be committed
# again after this. The already-processed WebPs live in the public bucket and
# are unaffected, so the thumbnails set above keep working.
assert_http 409 POST "$KANAE/projects/$PROJECT_ID/thumbnail/commit" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "{\"hash\":\"$THUMB_SRC_HASH\",\"content_type\":\"$THUMB_SRC_CT\",\"size\":$((THUMB_SRC_SIZE + 1))}"

ok "source object was discarded by the size-mismatch guard"

# ── done ──────────────────────────────────────────────────────────────────────
printf '\n%sall media + thumbnail flow checks passed%s\n' "$GRN" "$RST"
printf "  identity id: %s\n" "$IDENTITY_ID"
printf "  project id:  %s\n" "$PROJECT_ID"
printf "  event id:    %s\n" "$EVENT_ID"
printf "  hashes:\n"
for h in "${HASHES[@]}"; do
	detail "$h"
done
