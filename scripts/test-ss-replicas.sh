#!/usr/bin/env bash
# Test StatefulSetReplicasMismatch by scaling mysql-release-primary 1 -> 2 with a
# temporary init container (sleep) keeping the new pod unready past for: 2m,
# then scaling back to 1 and removing the init container.
#
# Routing: app=kubernetes -> Gmail (firing + resolved emails).
# Expected timeline: firing ~2.5-3 min after scale-up, resolved ~1-2 min after scale-down.
#
# Side effects (cleaned up by the script):
#   - orphaned PVC data-mysql-release-primary-1 (8Gi, whenScaled: Retain) — deleted at the end
#   - one rolling restart of mysql-release-primary-0 (init-container removal)
#
# Usage: ./scripts/test-ss-replicas.sh
set -euo pipefail

NS=default
STS=mysql-release-primary
SLEEP=240

cleanup() {
  echo "=== cleanup ==="
  kubectl -n "$NS" scale statefulset "$STS" --replicas=1
  kubectl -n "$NS" patch statefulset "$STS" --type='json' -p='[
    {"op":"remove","path":"/spec/template/spec/initContainers"}
  ]' || true
  kubectl -n "$NS" rollout status statefulset "$STS" --timeout=5m
  kubectl -n "$NS" delete pvc "data-${STS}-1" --ignore-not-found
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=mysql
  kubectl -n "$NS" get pvc | grep mysql
}
trap cleanup EXIT

echo "adding temporary init container (sleep ${SLEEP}) at $(date -u +%H:%M:%S)"
kubectl -n "$NS" patch statefulset "$STS" --type='json' -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/initContainers\",\"value\":[
    {\"name\":\"slow-start\",\"image\":\"bitnamilegacy/mongodb:8.0.13\",\"command\":[\"sh\",\"-c\",\"sleep ${SLEEP}\"]}
  ]}
]"

echo "scaling to 2 at $(date -u +%H:%M:%S)"
kubectl -n "$NS" scale statefulset "$STS" --replicas=2

echo "holding ~4 min for the alert to fire (for: 2m)..."
sleep 240

echo "=== done — check the Gmail inbox for the FIRING email (resolved follows after cleanup) ==="
