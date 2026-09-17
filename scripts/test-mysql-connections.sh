#!/usr/bin/env bash
# Test MysqlTooManyConnections by holding ~140 long-lived `SELECT SLEEP()`
# connections per instance (max_connections=151, alert threshold >90% = 136).
#
# Routing: app=mysql -> Rocket.Chat #dev-alerts (firing + resolved messages).
# Expected timeline: firing ~3 min after start (for: 2m), resolved ~HOLD+30s
# (connections drop on their own) — the RESOLVED *message* arrives ~5 min later
# due to Alertmanager's default resolve_timeout.
#
# Key mechanic: SELECT SLEEP connections are killed when the kubectl exec stream
# closes, so the load is launched from a single exec per pod that blocks on
# `wait` for the whole hold.
#
# Usage: ./scripts/test-mysql-connections.sh
set -euo pipefail

NS=default
CONNS=140
HOLD=480

launch_load() {
  local pod=$1
  kubectl -n "$NS" exec "$pod" -c mysql -- bash -c "
    for i in \$(seq 1 ${CONNS}); do
      mysql -u\"\$MYSQL_USER\" -p\"\$MYSQL_PASSWORD\" -e 'SELECT SLEEP(${HOLD})' >/dev/null 2>&1 &
    done
    wait
  " >/tmp/mysql-conn-load-${pod}.log 2>&1 &
  echo "$!"
}

P1=$(launch_load mysql-release-primary-0)
P2=$(launch_load mysql-release-secondary-0)
echo "load launched (pids ${P1} ${P2}) at $(date -u +%H:%M:%S)"

# confirm connections landed (INFO matches a running SELECT SLEEP, COMMAND=Query)
sleep 12
for pod in mysql-release-primary-0 mysql-release-secondary-0; do
  n=$(kubectl -n "$NS" exec "$pod" -c mysql -- bash -c \
    "mysql -u\"\$MYSQL_USER\" -p\"\$MYSQL_PASSWORD\" -e 'SELECT COUNT(*) FROM performance_schema.processlist WHERE INFO LIKE \"SELECT SLEEP%\";' 2>/dev/null | tail -1")
  echo "$pod live_connections=$n"
done

echo "connections self-drop after ~${HOLD}s — poll Prometheus /api/v1/alerts"
wait "$P1" "$P2"

echo "load done at $(date -u +%H:%M:%S) — threads_connected should return to baseline"
