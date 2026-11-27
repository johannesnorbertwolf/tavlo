#!/usr/bin/env bash
# Deploy the Worker to staging or production (REFERENCE.md "Runbook → Deploy"):
#   1. refuse while wrangler.jsonc still has the placeholder D1 id for that environment,
#   2. apply pending D1 migrations (remote),
#   3. deploy with the commit stamped into GIT_COMMIT,
#   4. check that /health?deep=1 answers with that commit.
# Auth: CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID in the environment (CI), or a
# local `wrangler login`.
set -euo pipefail

env="${1:-}"
case "$env" in
  staging | production) ;;
  *) echo "usage: scripts/deploy.sh staging|production" >&2; exit 2 ;;
esac
cd "$(dirname "$0")/.."

upper=$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')
if grep -q "REPLACE_WITH_${upper}_D1_ID" wrangler.jsonc; then
  echo "wrangler.jsonc still has REPLACE_WITH_${upper}_D1_ID: run 'npx wrangler d1 create tavtav-$env' and paste the id (REFERENCE.md, Runbook)." >&2
  exit 3
fi

commit=$(git rev-parse --short=12 HEAD)
if [ -n "$(git status --porcelain -- .)" ]; then commit="$commit-dirty"; fi
export WRANGLER_SEND_METRICS=false

echo "==> D1 migrations ($env)"
npx wrangler d1 migrations apply DB --env "$env" --remote

echo "==> deploy $commit to $env"
log=$(mktemp)
npx wrangler deploy --env "$env" --var "GIT_COMMIT:$commit" --message "deploy $commit" 2>&1 | tee "$log"
url=$(grep -Eo 'https://[a-z0-9.-]+\.workers\.dev' "$log" | head -n 1 || true)
rm -f "$log"
if [ -z "$url" ]; then
  echo "No workers.dev URL in the deploy output; skipping the health check." >&2
  exit 0
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "url=$url" >>"$GITHUB_OUTPUT"; fi

echo "==> health check $url"
body=""
for _ in 1 2 3 4 5 6; do
  body=$(curl -fsS "$url/health?deep=1" || true)
  if printf '%s' "$body" | grep -q "\"commit\":\"$commit\"" &&
    printf '%s' "$body" | grep -q '"status":"ok"'; then
    echo "$body"
    exit 0
  fi
  sleep 5
done
echo "Health check failed (expected commit $commit): $body" >&2
exit 1
