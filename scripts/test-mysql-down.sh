#!/usr/bin/env bash
# Test MysqlAllInstancesDown by scaling BOTH MySQL StatefulSets to 0, holding
# long enough for PromQL 5-min staleness + for: 1m, then restoring.
#
# Routing: app=mysql -> Rocket.Chat #dev-alerts (firing + resolved messages).
# Expected timeline: firing ~6-7 min after start, resolved ~2 min after restore.
#
# Usage: ./scripts/test-mysql-down.sh
set -euo pipefail

NS=default
PRIMARY=mysql-release-primary
SECONDARY=mysql-release-secondary
HOLD=420

echo "scaling both StatefulSets to 0 at $(date -u +%H:%M:%S)"
kubectl -n "$NS" scale statefulset "$PRIMARY" "$SECONDARY" --replicas=0

echo "holding ${HOLD}s (budget: ~5m staleness + 1m for + margin)"
sleep "$HOLD"

echo "restoring to 1 at $(date -u +%H:%M:%S)"
kubectl -n "$NS" scale statefulset "$PRIMARY" "$SECONDARY" --replicas=1

echo "waiting for pods to be ready..."
kubectl -n "$NS" rollout status statefulset "$PRIMARY" --timeout=5m
kubectl -n "$NS" rollout status statefulset "$SECONDARY" --timeout=5m

kubectl -n "$NS" get pods -l app.kubernetes.io/name=mysql
echo "done at $(date -u +%H:%M:%S) — check #dev-alerts for the FIRING + RESOLVED pair"
