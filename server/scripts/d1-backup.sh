#!/usr/bin/env bash
# Export an environment's D1 database to a gzipped SQL dump in server/backups/
# (gitignored), and print the current Time Travel bookmark next to it. D1 Time Travel
# already keeps 7 days (free plan) of point-in-time history; this is the off-Cloudflare
# copy (REFERENCE.md "Runbook → Backups"). Note: an export blocks the database while it
# runs, so run it off-peak.
set -euo pipefail

env="${1:-}"
case "$env" in
  staging | production) ;;
  *) echo "usage: scripts/d1-backup.sh staging|production" >&2; exit 2 ;;
esac
cd "$(dirname "$0")/.."
export WRANGLER_SEND_METRICS=false

stamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p backups
file="backups/tavtav-$env-$stamp.sql"

npx wrangler d1 time-travel info "tavtav-$env" --env "$env" | tee "backups/tavtav-$env-$stamp.bookmark.txt"
npx wrangler d1 export "tavtav-$env" --env "$env" --remote --output "$file"
gzip -9 "$file"
echo "Backup written to server/$file.gz"
