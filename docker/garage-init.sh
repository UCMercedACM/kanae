#!/usr/bin/env bash
set -euo pipefail

CONFIG="${CONFIG:-/kanae/config.yml}"
GARAGE_S3_URL="${GARAGE_S3_URL:-http://127.0.0.1:3900}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

GARAGE_KEY_ID=$(yq '.storage.key_id' "$CONFIG")
GARAGE_SECRET_KEY=$(yq '.storage.secret_key' "$CONFIG")
GARAGE_BUCKET=$(yq '.storage.bucket' "$CONFIG")
GARAGE_PUBLIC_BUCKET=$(yq '.storage.public.bucket' "$CONFIG")
export AWS_ACCESS_KEY_ID="$GARAGE_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$GARAGE_SECRET_KEY"

if garage bucket info "$GARAGE_BUCKET" >/dev/null 2>&1; then
	log "Garage already bootstrapped (bucket $GARAGE_BUCKET exists) — skipping init."
	exit 0
fi

if garage layout show 2>/dev/null | grep -qi 'no nodes currently have a role'; then
	NODE_ID=$(garage status 2>/dev/null \
		| awk '/HEALTHY NODES/{f=2; next} f==2{f=1; next} f==1 && NF{print $1; exit}')
	log "assigning layout to node: $NODE_ID"
	garage layout assign -z dc1 -c 5G "$NODE_ID"
	garage layout apply --version 1
else
	log "layout already applied — skipping assign/apply"
fi

if garage key info "$GARAGE_KEY_ID" >/dev/null 2>&1; then
	log "access key $GARAGE_KEY_ID already imported — skipping"
else
	log "importing access key"
	garage key import --yes -n kanae "$GARAGE_KEY_ID" "$GARAGE_SECRET_KEY"
fi

if garage bucket info "$GARAGE_BUCKET" >/dev/null 2>&1; then
	log "private bucket $GARAGE_BUCKET already exists — skipping create"
else
	log "creating private bucket"
	garage bucket create "$GARAGE_BUCKET"
fi

log "granting key access to private bucket"
garage bucket allow --read --write --owner "$GARAGE_BUCKET" --key "$GARAGE_KEY_ID"

log "setting private bucket CORS policy"
aws s3api put-bucket-cors \
	--endpoint-url "$GARAGE_S3_URL" \
	--bucket "$GARAGE_BUCKET" \
	--cors-configuration '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","PUT","HEAD"],"AllowedHeaders":["*"],"MaxAgeSeconds":3600}]}' \
	--region garage

log "setting private bucket lifecycle (abort stale multipart after 1 day)"
aws s3api put-bucket-lifecycle-configuration \
	--endpoint-url "$GARAGE_S3_URL" \
	--bucket "$GARAGE_BUCKET" \
	--lifecycle-configuration '{"Rules":[{"ID":"abort-stale-multipart","Status":"Enabled","Filter":{"Prefix":"media/"},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}' \
	--region garage

if garage bucket info "$GARAGE_PUBLIC_BUCKET" >/dev/null 2>&1; then
	log "public bucket $GARAGE_PUBLIC_BUCKET already exists — skipping create"
else
	log "creating public bucket for thumbnails"
	garage bucket create "$GARAGE_PUBLIC_BUCKET"
fi

log "granting key access to public bucket + enabling website mode"
garage bucket allow --read --write --owner "$GARAGE_PUBLIC_BUCKET" --key "$GARAGE_KEY_ID"
garage bucket website --allow "$GARAGE_PUBLIC_BUCKET"

log "setting public bucket CORS policy"
aws s3api put-bucket-cors \
	--endpoint-url "$GARAGE_S3_URL" \
	--bucket "$GARAGE_PUBLIC_BUCKET" \
	--cors-configuration '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","HEAD"],"AllowedHeaders":["*"],"MaxAgeSeconds":86400}]}' \
	--region garage

log "Garage setup complete."
