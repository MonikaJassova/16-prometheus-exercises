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

# 404 burst — ~300 reqs spread over ~150s, Host header required so it feeds the
# per-status histogram the 4xx alert reads. It must run LONGER than the alert's
# `for: 2m`: nginx_ingress_controller_requests is a counter, so rate() collapses to
# 0 the moment the burst stops (a flat counter has slope 0). A ~60s burst therefore
# never lets the 2m `for` elapse. ~2 rps keeps the 4xx ratio above 5% (with the 200
# burst's ~20 rps diluting the denominator to ~9%, see Gotcha 2) for the whole 150s.
(
  for i in $(seq 1 150); do
    curl -s -o /dev/null -H "Host: java-app.local" "http://${IP}/path-$(date +%s%N)" &
    curl -s -o /dev/null -H "Host: java-app.local" "http://${IP}/path-$(date +%s%N)" &
    sleep 1
  done
  wait
) &
BURST404=$!

# 200 burst — 3600 reqs at ~20 rps over ~180s, with the Host header so it ALSO feeds
# the per-status denominator (diluting the 4xx ratio, Gotcha 2). It still hits the
# java-app pods (the Host header does not block the request), so it drives
# JavaAppTooManyRequests regardless.
for i in $(seq 1 180); do
  for j in $(seq 1 20); do curl -s -o /dev/null -H "Host: java-app.local" "http://${IP}/get-data" & done
  sleep 1
done
wait "$BURST404"

echo "bursts done at $(date -u +%H:%M:%S) — poll Prometheus /api/v1/alerts"
