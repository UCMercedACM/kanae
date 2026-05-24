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
# Reuses the registration + role + project setup from test-flow.sh and then
# pushes every file in ./test-images through the full upload flow — single
# PUT for files ≤ 16 MB, multipart for anything larger — plus a set of
# negative cases for the validation guards.
#
# Run after `docker compose up -d`. Garage must be initialized too
# (`mise run garage:setup`). Requires: curl, jq, docker, uvx (mise),
# python3 (stdlib only — used for chunk slicing + per-part PUTs).

set -euo pipefail

# ── locate ourselves ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
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
SINGLE_PUT_MAX=$((16 * 1024 * 1024))    # mirrors _SINGLE_PUT_MAX in projects.py

# ── config ────────────────────────────────────────────────────────────────────
KRATOS_PUBLIC=${KRATOS_PUBLIC:-http://localhost:4433}
KETO_WRITE=${KETO_WRITE:-http://localhost:4467}
KANAE=${KANAE:-http://localhost:8000}
DB_CONTAINER=${DB_CONTAINER:-kanae_postgres}
VALKEY_CONTAINER=${VALKEY_CONTAINER:-kanae_valkey}
DB_NAME=${DB_NAME:-kanae}
DB_USER=${DB_USER:-postgres}

COOKIES="$(mktemp -t kanae-images-cookies.XXXXXX)"
trap 'rm -f "$COOKIES"' EXIT

EMAIL="images-$(date +%s)-$$@ucmerced.edu"
PASSWORD="correct-horse-battery-staple-2026"
NAME="Images Test"

# ── output helpers ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YEL=$'\033[0;33m'
BLU=$'\033[0;34m'
RST=$'\033[0m'

step() { printf "\n${BLU}━━ %s ━━${RST}\n" "$1"; }
ok()   { printf "${GRN}✓${RST} %s\n" "$1"; }
warn() { printf "${YEL}⚠${RST} %s\n" "$1"; }
fail() { printf "${RED}✗${RST} %s\n" "$1" >&2; exit 1; }

require() {
  command -v "$1" > /dev/null 2>&1 || fail "missing required tool: $1"
}

assert_http() {
  # assert_http <expected-status> <method> <url> [curl args...]
  local expected="$1" method="$2" url="$3"; shift 3
  local actual
  actual="$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$url" "$@")"
  if [[ "$actual" != "$expected" ]]; then
    fail "expected HTTP $expected from $method $url, got $actual"
  fi
  ok "$method $url -> $actual"
}

# Compute a file's BLAKE3 hex digest. Uses uvx so we don't depend on the
# project's venv being active.
blake3_hash() {
  uvx --quiet --from blake3 python -c '
import sys
from blake3 import blake3
with open(sys.argv[1], "rb") as f:
    print(blake3(f.read()).hexdigest())
' "$1"
}

# Derive a content-type from a file extension. Returns 1 if unrecognized.
content_type_for() {
  local ext="${1##*.}"
  case "${ext,,}" in
    gif)       echo "image/gif" ;;
    png)       echo "image/png" ;;
    jpg|jpeg)  echo "image/jpeg" ;;
    webp)      echo "image/webp" ;;
    mp4)       echo "video/mp4" ;;
    webm)      echo "video/webm" ;;
    mov)       echo "video/quicktime" ;;
    *)         return 1 ;;
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

curl -sf "$KRATOS_PUBLIC/health/ready" > /dev/null || fail "kratos not ready at $KRATOS_PUBLIC"
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
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -X POST "$KRATOS_PUBLIC/self-service/registration?flow=$FLOW" \
  -d '{
    "method": "password",
    "csrf_token": "'"$CSRF"'",
    "password":   "'"$PASSWORD"'",
    "traits": { "email": "'"$EMAIL"'", "name": "'"$NAME"'" }
  }')

IDENTITY_ID=$(jq -r '.identity.id // empty' <<< "$REG_RESP")
[[ -n "$IDENTITY_ID" ]] \
  || fail "registration failed: $(jq -c '.ui.messages // .error // .' <<< "$REG_RESP")"
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
  -H "Content-Type: application/json" \
  -d '{
    "namespace":  "Role",
    "object":     "manager",
    "relation":   "member",
    "subject_id": "'"$IDENTITY_ID"'"
  }' > /dev/null
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB > /dev/null
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
  -H "Content-Type: application/json" \
  -d "$PROJ_BODY")
PROJECT_ID=$(jq -r '.id // empty' <<< "$CREATE_RESP")
[[ -n "$PROJECT_ID" ]] || fail "project create failed: $CREATE_RESP"
ok "project id: $PROJECT_ID"

step "5. grant Project owners"

curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace":  "Project",
    "object":     "'"$PROJECT_ID"'",
    "relation":   "owners",
    "subject_id": "'"$IDENTITY_ID"'"
  }' > /dev/null
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB > /dev/null
ok "owner tuple written, cache flushed"

# ── upload helpers ────────────────────────────────────────────────────────────

# Single-PUT path: declare, presign, PUT bytes, commit.
upload_single() {
  local file="$1" hash="$2" size="$3" content_type="$4"

  local upload_resp
  upload_resp=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/media/upload" \
    -b "$COOKIES" \
    -H "Content-Type: application/json" \
    -d "{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size}")

  # Dedup path: response is a MediaRecord (has a `hash` field). Nothing to PUT.
  if [[ "$(jq -r 'has("hash")' <<< "$upload_resp")" == "true" ]]; then
    return 0
  fi

  local url
  url=$(jq -r '.url // empty' <<< "$upload_resp")
  [[ -n "$url" ]] || fail "no presigned url in upload response: $upload_resp"

  local put_code
  put_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT "$url" \
    -H "Content-Type: $content_type" \
    --data-binary "@$file")
  [[ "$put_code" =~ ^2[0-9][0-9]$ ]] \
    || fail "PUT to presigned url returned $put_code (expected 2xx)"

  local commit_resp commit_hash
  commit_resp=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/media/commit" \
    -b "$COOKIES" \
    -H "Content-Type: application/json" \
    -d "{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size}")
  commit_hash=$(jq -r '.hash // empty' <<< "$commit_resp")
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
    -H "Content-Type: application/json" \
    -d "{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size}")

  # Dedup path: response is a MediaRecord. Nothing to upload.
  if [[ "$(jq -r 'has("hash")' <<< "$upload_resp")" == "true" ]]; then
    return 0
  fi

  local upload_id chunks
  upload_id=$(jq -r '.upload_id // empty' <<< "$upload_resp")
  chunks=$(jq -c '.chunks // empty' <<< "$upload_resp")
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
    -H "Content-Type: application/json" \
    -d "{\"hash\":\"$hash\",\"content_type\":\"$content_type\",\"size\":$size,\"upload_id\":\"$upload_id\",\"chunks\":$completed}")
  commit_hash=$(jq -r '.hash // empty' <<< "$commit_resp")
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

  if (( size <= SINGLE_PUT_MAX )); then
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
LIST_COUNT=$(jq 'length' <<< "$LIST_RESP")
[[ "$LIST_COUNT" -eq "${#HASHES[@]}" ]] \
  || fail "expected ${#HASHES[@]} media rows, got $LIST_COUNT: $LIST_RESP"
ok "list returned $LIST_COUNT items"

ok "presigned GET URLs (copy to verify the bytes landed):"
for i in "${!MEDIA_FILES[@]}"; do
  hash="${HASHES[$i]}"
  file="${MEDIA_FILES[$i]}"
  url=$(jq -r --arg h "$hash" '.[] | select(.hash == $h) | .url // empty' <<< "$LIST_RESP")
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
  -H "Content-Type: application/json" \
  -d "{\"hash\":\"$FIRST_HASH\",\"content_type\":\"$FIRST_CT\",\"size\":$FIRST_SIZE}")
DEDUP_HASH=$(jq -r '.hash // empty' <<< "$DEDUP_RESP")
[[ "$DEDUP_HASH" == "$FIRST_HASH" ]] \
  || fail "dedup did not return existing record: $DEDUP_RESP"
ok "dedup returned existing record"

# ── 9. negative: invalid content-type -> 415 ──────────────────────────────────
step "9. POST /media/upload with disallowed content-type -> 415"

assert_http 415 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
  -b "$COOKIES" \
  -H "Content-Type: application/json" \
  -d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"application/pdf","size":1024}'

# ── 10. negative: zero size -> 400 ────────────────────────────────────────────
step "10. POST /media/upload with size=0 -> 400"

assert_http 400 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
  -b "$COOKIES" \
  -H "Content-Type: application/json" \
  -d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"image/gif","size":0}'

# ── 11. negative: oversized image -> 413 ──────────────────────────────────────
step "11. POST /media/upload with image size > 32 MB -> 413"

assert_http 413 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
  -b "$COOKIES" \
  -H "Content-Type: application/json" \
  -d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"image/gif","size":40000000}'

# ── 12. negative: oversized video -> 413 ──────────────────────────────────────
step "12. POST /media/upload with video size > 2 GB -> 413"

assert_http 413 POST "$KANAE/projects/$PROJECT_ID/media/upload" \
  -b "$COOKIES" \
  -H "Content-Type: application/json" \
  -d '{"hash":"deadbeefcafebabefacefedbadc0debead5badc0ffeefedfeedbabec0dedeadc","content_type":"video/mp4","size":3000000000}'

# ── 13. reorder: reverse the list ─────────────────────────────────────────────
step "13. PUT /media/positions reverses the order"

REVERSED=$(printf '%s\n' "${HASHES[@]}" | tac | jq -R . | jq -sc .)
REORDER_RESP=$(curl -s -X PUT "$KANAE/projects/$PROJECT_ID/media/positions" \
  -b "$COOKIES" \
  -H "Content-Type: application/json" \
  -d "{\"hashes\":$REVERSED}")
REORDER_MSG=$(jq -r '.message // empty' <<< "$REORDER_RESP")
[[ -n "$REORDER_MSG" ]] || fail "reorder failed: $REORDER_RESP"
ok "reorder accepted (message: $REORDER_MSG)"

# ── 14. verify reorder ────────────────────────────────────────────────────────
step "14. GET /media reflects new order"

LIST_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID/media")
ACTUAL_FIRST=$(jq -r '.[0].hash // empty' <<< "$LIST_RESP")
EXPECTED_FIRST="${HASHES[-1]}"
[[ "$ACTUAL_FIRST" == "$EXPECTED_FIRST" ]] \
  || fail "first item is $ACTUAL_FIRST, expected $EXPECTED_FIRST (reversed)"
ok "first item is now the previously-last upload"

# ── 15. negative: reorder with unknown hash -> 404 ────────────────────────────
step "15. PUT /media/positions with hash not in project -> 404"

assert_http 404 PUT "$KANAE/projects/$PROJECT_ID/media/positions" \
  -b "$COOKIES" \
  -H "Content-Type: application/json" \
  -d '{"hashes":["0000000000000000000000000000000000000000000000000000000000000000"]}'

# ── 16. delete one media ──────────────────────────────────────────────────────
step "16. DELETE /media/<hash> removes last uploaded hash"

TO_DELETE="${HASHES[-1]}"
assert_http 200 DELETE "$KANAE/projects/$PROJECT_ID/media/$TO_DELETE" -b "$COOKIES"

# ── 17. list reflects deletion ────────────────────────────────────────────────
step "17. GET /media reflects deletion"

LIST_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID/media")
LIST_COUNT=$(jq 'length' <<< "$LIST_RESP")
EXPECTED=$(( ${#HASHES[@]} - 1 ))
[[ "$LIST_COUNT" -eq "$EXPECTED" ]] \
  || fail "expected $EXPECTED media after delete, got $LIST_COUNT"
ok "list returned $LIST_COUNT items"

jq -e --arg h "$TO_DELETE" 'all(.[]; .hash != $h)' <<< "$LIST_RESP" > /dev/null \
  || fail "deleted hash $TO_DELETE still present in list"
ok "deleted hash is gone from list"

# ── 18. negative: re-delete same hash -> 404 ──────────────────────────────────
step "18. DELETE /media/<hash> for already-detached hash -> 404"

assert_http 404 DELETE "$KANAE/projects/$PROJECT_ID/media/$TO_DELETE" -b "$COOKIES"

# ── 19. final URL list (post-delete) ──────────────────────────────────────────
step "19. surviving media — copy any of these URLs to verify they still work"

FINAL_LIST=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID/media")
FINAL_COUNT=$(jq 'length' <<< "$FINAL_LIST")
printf "    %d files left in project\n" "$FINAL_COUNT"
for i in "${!MEDIA_FILES[@]}"; do
  hash="${HASHES[$i]}"
  file="${MEDIA_FILES[$i]}"
  url=$(jq -r --arg h "$hash" '.[] | select(.hash == $h) | .url // empty' <<< "$FINAL_LIST")
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
  -H "Content-Type: application/json" \
  -d "{\"hash\":\"$THUMB_SRC_HASH\",\"content_type\":\"$THUMB_SRC_CT\"}")
THUMB_MSG=$(jq -r '.message // empty' <<< "$THUMB_RESP")
[[ -n "$THUMB_MSG" ]] || fail "thumbnail set failed: $THUMB_RESP"
ok "thumbnail processed and recorded (message: $THUMB_MSG)"

# ── 21. GET /projects/{id} returns thumbnail object ───────────────────────────
step "21. GET /projects/{id} returns thumbnail {hash, url}"

PROJ_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID")
THUMB_OBJ=$(jq -c '.thumbnail' <<< "$PROJ_RESP")
[[ -n "$THUMB_OBJ" && "$THUMB_OBJ" != "null" ]] \
  || fail "thumbnail missing from project response: $PROJ_RESP"

THUMB_HASH=$(jq -r '.hash // empty' <<< "$THUMB_OBJ")
THUMB_URL=$(jq -r '.url // empty' <<< "$THUMB_OBJ")
[[ -n "$THUMB_HASH" && -n "$THUMB_URL" ]] \
  || fail "thumbnail object missing hash or url: $THUMB_OBJ"
ok "thumbnail.hash = $THUMB_HASH"
printf "    %s\n" "$THUMB_URL"

# ── 22. thumbnail URL is anonymously reachable and returns webp ───────────────
step "22. GET <thumbnail_url> returns 200 + image/webp"

THUMB_CHECK=$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$THUMB_URL")
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
LIST_THUMB=$(jq -c --arg id "$PROJECT_ID" '.data[] | select(.id == $id) | .thumbnail' <<< "$LIST_PROJ_RESP")
[[ -n "$LIST_THUMB" && "$LIST_THUMB" != "null" ]] \
  || fail "thumbnail missing from /projects listing: $LIST_PROJ_RESP"

LIST_THUMB_HASH=$(jq -r '.hash' <<< "$LIST_THUMB")
LIST_THUMB_URL=$(jq -r '.url' <<< "$LIST_THUMB")
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
    -H "Content-Type: application/json" \
    -d "{\"hash\":\"$THUMB_ALT_HASH\",\"content_type\":\"$THUMB_ALT_CT\"}" > /dev/null \
    || fail "replacement POST failed"

  NEW_RESP=$(curl -s -b "$COOKIES" "$KANAE/projects/$PROJECT_ID")
  NEW_HASH=$(jq -r '.thumbnail.hash // empty' <<< "$NEW_RESP")
  NEW_URL=$(jq -r '.thumbnail.url // empty' <<< "$NEW_RESP")
  [[ -n "$NEW_HASH" && "$NEW_HASH" != "$THUMB_HASH" ]] \
    || fail "thumbnail hash did not change after replacement (still $NEW_HASH)"
  ok "thumbnail hash updated: $THUMB_HASH -> $NEW_HASH"
fi

# ── 25. negative: video content-type rejected ─────────────────────────────────
step "25. POST /thumbnail with video content-type -> 400"

assert_http 400 POST "$KANAE/projects/$PROJECT_ID/thumbnail" \
  -b "$COOKIES" \
  -H "Content-Type: application/json" \
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
POST_DELETE_THUMB=$(jq -r '.thumbnail' <<< "$POST_DELETE")
[[ "$POST_DELETE_THUMB" == "null" ]] \
  || fail "thumbnail not cleared from project: $POST_DELETE_THUMB"
ok "project.thumbnail is null after DELETE"

DEL_CHECK=$(curl -s -o /dev/null -w '%{http_code}' "$CURRENT_URL")
if [[ "$DEL_CHECK" == "404" ]]; then
  ok "thumbnail URL now returns 404 anonymously"
else
  warn "expected 404 for removed thumbnail URL, got $DEL_CHECK ($CURRENT_URL)"
fi

# ── 28. DELETE is idempotent — second call still returns 200 ──────────────────
step "28. DELETE /projects/{id}/thumbnail is idempotent"

assert_http 200 DELETE "$KANAE/projects/$PROJECT_ID/thumbnail" -b "$COOKIES"

# ── done ──────────────────────────────────────────────────────────────────────
printf "\n${GRN}all media + thumbnail flow checks passed${RST}\n"
printf "  identity id: %s\n" "$IDENTITY_ID"
printf "  project id:  %s\n" "$PROJECT_ID"
printf "  hashes:\n"
for h in "${HASHES[@]}"; do
  printf "    %s\n" "$h"
done
