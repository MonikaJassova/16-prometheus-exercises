#!/usr/bin/env bash
# Trigger both Exercise 5 alerts with sized traffic bursts:
#   - 404 burst  -> NginxIngressHigh4xxRatio (email route)
#   - 200 burst  -> JavaAppTooManyRequests   (chat route)
# Usage: ./scripts/test-alerts.sh <elb-ip>
set -euo pipefail

IP="${1:?usage: $0 <elb-ip>}"

# Pre-check: verify the ingress is reachable before starting a timing-sensitive burst
# (|| true: a refused connection makes curl exit non-zero, which set -e would abort before the check)
code=$(curl -s -o /dev/null -w "%{http_code}" "http://${IP}/get-data" || true)
if [ "$code" != "200" ]; then
  echo "ERROR: http://${IP}/get-data returned ${code} — aborting" >&2
  exit 1
fi
echo "ingress reachable (${code}), starting bursts at $(date -u +%H:%M:%S)"

# 404 burst — 300 reqs / ~60s, Host header required for per-status metrics
(
  for i in $(seq 1 300); do
    curl -s -o /dev/null -H "Host: java-app.local" "http://${IP}/path-that-doesnt-exist" &
    [ $((i % 20)) -eq 0 ] && wait -n
  done
  wait
) &
BURST404=$!

# 200 burst — 3600 reqs at ~20 rps over ~180s
for i in $(seq 1 180); do
  for j in $(seq 1 20); do curl -s -o /dev/null "http://${IP}/get-data" & done
  sleep 1
done
wait "$BURST404"

echo "bursts done at $(date -u +%H:%M:%S) — poll Prometheus /api/v1/alerts"
