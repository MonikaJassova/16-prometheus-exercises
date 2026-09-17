#### This project is for the DevOps bootcamp exercise for

- "Monitoring - Prometheus"

The application runs on port 8080 and exposes metrics on port 8081

## Deploying Own (Java) Application

1. Built the sample Java app and pushed an image to a private DockerHub repo:

   - `mise exec -- gradle clean build`
   - `podman build -t docker.io/monikajassova/demo-app:java-prometheus .`
   - `podman push docker.io/monikajassova/demo-app:java-prometheus`

1. Provisioned a T Cloud Public CCE cluster (managed K8s) including the MySQL with 2 replicas using Terraform. The infrastructure lives in the sibling [12-terraform-exercises repo](https://github.com/MonikaJassova/terraform-exercises/tree/prometheus-java) under `environments/prometheus/`.

   - initialised and applied it: `mise exec -- terraform -chdir=environments/prometheus init` then `mise exec -- terraform -chdir=environments/prometheus apply --auto-approve`
   - generated a kubeconfig pointing at the cluster's public EIP: `mise exec -- bash generate-kubeconfig.sh prometheus` (writes environments/prometheus/kubeconfig.yaml)
   - mise.toml sets KUBECONFIG to point to the generated file, so `mise exec -- kubectl` and `mise exec -- helm` commands target the CCE cluster

1. Installed Nginx Ingress Controller as a Helm chart to the cluster:
   - `helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx`
   - `helm repo update`

   - ```bash
      helm install ingress ingress-nginx/ingress-nginx \
         -n ingress --create-namespace \
         --wait --timeout 10m \
         -f k8s/ingress-values.yaml
     ```

1. Wrote K8s config files for the sample Java app with 3 replicas, Ingress rule, DockerHub and DB Secrets, DB ConfigMap, and deployed everything to the cluster:
   - `kubectl apply -f k8s/db-secret.yaml`
   - `kubectl apply -f k8s/db-config.yaml`
   - `kubectl create secret docker-registry my-registry-key --docker-server=docker.io --docker-username=monikajassova --docker-password=<pwd>`
   - `kubectl apply -f k8s/java-app.yaml`
   - `kubectl apply -f k8s/ingress.yaml`

   Verified the deployment end-to-end:

   - `kubectl get deploy java-app-deployment` → `3/3 READY`, `3 UP-TO-DATE`, `3 AVAILABLE`
   - `kubectl get pods -l app=java-app` → 3 pods `1/1 Running`, 0 restarts
   - `kubectl get endpoints java-app-service` → 3 endpoint IPs (one per replica)
   - `curl -s http://80.158.5.59/get-data` → HTTP 200 with live data from MySQL
   - `kubectl logs -n ingress deploy/ingress-ingress-nginx-controller` → requests from the ingress load balancer across all 3 pod IPs (`172.16.0.21`, `172.16.0.39`, `172.16.0.51`)

## Monitoring the Applications

1. Deployed Prometheus stack using Prometheus Operator Helm chart (kube-prometheus-stack):

   - added the Helm repo: `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts`
   - updated the index: `helm repo update`
   - created a separate namespace: `kubectl create ns monitoring`
   - installed the Helm chart: `helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --wait --timeout 10m`

   Verified the deployment end-to-end:

   - all components are Running: `kubectl -n monitoring get pods -l "release=monitoring"` → all pods `x/x Running`, 0 restarts
   - Prometheus is serving and scraping its built-in targets: `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 19090:9090`, then `curl -s http://localhost:19090/api/v1/targets` → all built-in targets (apiserver, kubelet, node-exporter, kube-state-metrics, ...) `up`

1. For Nginx Controller monitoring, the chart ships a Prometheus metrics endpoint, but it has to be enabled - adjusted `k8s/ingress-values.yaml` (metrics enabled + ServiceMonitor labelled with `release: monitoring` so the stack's Prometheus picks it up) and applied: `helm upgrade ingress ingress-nginx/ingress-nginx -n ingress -f k8s/ingress-values.yaml --wait --timeout 10m`

   - verified: `kubectl -n ingress get svc ingress-ingress-nginx-controller-metrics` exists, and in Prometheus targets `curl -s http://localhost:19090/api/v1/targets` shows the `ingress-ingress-nginx-controller-metrics` job `up`
   - sample metric: `curl -s "http://localhost:19090/api/v1/query" --data-urlencode 'query=nginx_ingress_controller_nginx_process_requests_total'` returns data

1. For MySQL monitoring, the chart also exposes Prometheus metrics - created `k8s/mysql-values.yaml` (metrics enabled + ServiceMonitor labelled with `release: monitoring`; exporter image pinned to `bitnamilegacy/mysqld-exporter`) and applied it, pinning the chart version so the release stays on 9.4.0: `helm upgrade mysql-release bitnami/mysql -n default --version 9.4.0 --reuse-values -f k8s/mysql-values.yaml --wait --timeout 10m` (for exercise simplicity, one-off override of the Helm release managed by Terraform - the change would be rolled back by the next Terraform apply and the configuration would ideally move to the Terraform repo)

   - verified: MySQL pods are 2/2 Running (mysql + exporter sidecar): `kubectl -n default get pods -l app.kubernetes.io/instance=mysql-release`
   - in Prometheus targets the `mysql-release-metrics` job is `up` (2 targets - primary and secondary)
   - sample metrics: `curl -s "http://localhost:19090/api/v1/query" --data-urlencode 'query=mysql_up'` → 2 series = 1; `--data-urlencode 'query=mysql_global_status_threads_connected'` returns data

1. For Java app monitoring, the app exposes metrics on port 8081 - adjusted `k8s/java-app.yaml` to add a named `metrics` port (8081) to the Deployment and the Service (the Service also needs the `app: java-app` label, which the ServiceMonitor selector matches on), and deployed a ServiceMonitor for its Service:
   - `kubectl apply -f k8s/java-app.yaml`
   - `kubectl apply -f k8s/java-service-monitor.yaml`

   - verified: `kubectl get servicemonitor java-app-sm -n default` exists with label `release: monitoring`
   - in Prometheus targets the `java-app-service` job is `up` (3 targets - one per replica)
   - sample metric: `curl -s "http://localhost:19090/api/v1/query" --data-urlencode 'query=up{job="java-app-service"}'` → 3 series = 1

All three application metrics are collected (verified in the Prometheus targets API and via the sample queries above).

## Configuring Alert Rules

1. Configured alert rules for the critical issues described in the exercise — created `k8s/alert-rules.yaml` (a single `PrometheusRule` in the `monitoring` namespace, labelled `release: monitoring` so the stack's Prometheus picks it up, the same pattern as the ServiceMonitors) with 4 rule groups / 5 alerts, and applied it: `mise exec -- kubectl apply -f k8s/alert-rules.yaml`

    | Alert | Expression | For | Severity |
    |-------|-----------|-----|----------|
    | `NginxIngressHigh4xxRatio` | `sum(rate(nginx_ingress_controller_requests{status=~"4.."}[5m])) / sum(rate(nginx_ingress_controller_requests[5m])) > 0.05` | 2m | warning |
    | `MysqlAllInstancesDown` | `absent(mysql_up == 1) == 1 or count(mysql_up == 1) < count(mysql_up)` | 1m | critical |
    | `MysqlTooManyConnections` | `mysql_global_status_threads_connected / mysql_global_variables_max_connections > 0.9` | 2m | warning |
    | `JavaAppTooManyRequests` | `sum(rate(java_app_http_requests_total[5m])) > 10` | 2m | warning |
    | `StatefulSetReplicasMismatch` | `kube_statefulset_replicas != kube_statefulset_status_replicas_ready` | 2m | warning |

    Each alert carries an `app` label (`nginx-ingress` / `mysql` / `java-app` / `kubernetes`) for the notification routing in the next exercise.

    Verified the rules load and are healthy:

    - `mise exec -- kubectl get prometheusrule -n monitoring` → `app-alert-rules` present
    - via `port-forward` on the Prometheus service, `curl -s http://localhost:19090/api/v1/rules` → all 5 alert names present under their 4 groups, every one `state: inactive`, `health: ok`
    - expression sanity (each returns real data on the live cluster): `count(mysql_up == 1)` = 2 (both instances up), `mysql_global_status_threads_connected / mysql_global_variables_max_connections` = 0.033/0.007 (well under 90%), `sum(rate(java_app_http_requests_total[5m]))` = 0 req/s, `kube_statefulset_replicas != kube_statefulset_status_replicas_ready` = 0 series (all StatefulSets in sync)

    The `MysqlAllInstancesDown` expression was fixed during Exercise 5 (see the alert-testing section): the original `count(mysql_up == 1) == 0` could never fire when *all* instances are gone, because then the `mysql_up` series no longer exists and the query returns an empty vector (see Gotchas 6 & 7 in that section).

1. The Nginx 4xx alert depends on the per-status histogram `nginx_ingress_controller_requests`, which **only populates for requests whose `Host` header matches a DNS host defined in an Ingress** (see Gotchas 6 & 7). The original ingress was hostless (catch-all, reached via the ELB IP), so its 4xx traffic routed through the default server and never wrote the metric — the alert would stay inert. Fixed by updating `k8s/ingress.yaml` to two rules: `host: java-app.local` (measurable, drives the 4xx alert) **plus** the original hostless catch-all (keeps raw IP access working). Applied: `mise exec -- kubectl apply -f k8s/ingress.yaml`

    Verified end-to-end:

    - raw IP access still works: `curl -s -o /dev/null -w "%{http_code}" http://80.158.5.59/get-data` → `200`
    - host-scoped traffic populates the metric: `curl -s -H "Host: java-app.local" http://80.158.5.59/path-that-doesnt-exist` (a 404) → `/api/v1/query` for `nginx_ingress_controller_requests{host="java-app.local"}` shows both `status="200"` and `status="404"` series
    - the alert actually reacts: a burst of host-scoped 404s pushed the 4xx ratio to 0.5 (> 5%), and `/api/v1/alerts` showed `NginxIngressHigh4xxRatio` in `pending` state; clean host-scoped 200 traffic then diluted the ratio back to ~1.5% (< 5%) and the alert returned to `inactive`
    - final state: all 5 alerts `state: inactive`, `health: ok`

### Gotchas

1. **`helm upgrade` without `--version` resolves the chart to the latest, not the installed one.**
   `helm upgrade mysql-release bitnami/mysql ...` pulled chart 14.0.3 instead of the installed 9.4.0 and failed. Fix: always pin the chart version on upgrade: `--version 9.4.0`.

2. **Bitnami images no longer pull from DockerHub.**
   Fix: pin `metrics.image.repository: bitnamilegacy/mysqld-exporter` in `k8s/mysql-values.yaml` (the chart's own `image.repository: bitnamilegacy/mysql` already worked, which is how the problem was isolated to the exporter sidecar).

3. **A failed `helm upgrade` leaves the release in `failed` status AND the pods on the old spec.**
   After the failed upgrade, the StatefulSet template had the new image but the running pods kept the old one and sat in `ErrImagePull`/`ImagePullBackOff` — the controller did not recreate them on its own. Fix: `kubectl -n default delete pod mysql-release-primary-0 mysql-release-secondary-0` to force recreation, then re-run the same `helm upgrade` to flip the release status back to `deployed`.

4. **The stack's Prometheus only scrapes ServiceMonitors labelled `release: monitoring`.**
   kube-prometheus-stack's Prometheus uses `serviceMonitorSelector: matchLabels: {release: monitoring}` (all namespaces), so chart-created ServiceMonitors are invisible unless labelled. The values key differs per chart:
   - ingress-nginx: `controller.metrics.serviceMonitor.additionalLabels`
   - bitnami/mysql 9.4.0: `metrics.serviceMonitor.labels` (NOT `additionalLabels` — that key is ignored, the label silently never appears)
   - hand-written ServiceMonitor (`k8s/java-service-monitor.yaml`): plain `metadata.labels`
   Symptom: everything deploys fine, but the job never shows up in `/api/v1/targets`.

5. **The ServiceMonitor selector matches SERVICE labels, not pod labels.**
   `k8s/java-service-monitor.yaml` selects services with `app: java-app`, but the `java-app-service` Service had no `metadata.labels` — so every discovered target was silently dropped. No error anywhere: the job appears in the generated Prometheus config, targets exist in `/api/v1/targets?state=any` under `droppedTargets`, but never in `activeTargets`. Fix: add `labels: {app: java-app}` to the Service. Debugging tip: compare `state=any` vs `active` in the targets API to find silently dropped targets.

6. **An Ingress `host` must be a DNS name — K8s rejects an IP.**
   `spec.rules[].host: 80.158.5.59` fails validation: `spec.rules[0].host: Invalid value: "80.158.5.59": must be a DNS name, not an IP address`. Consequence: a browser hitting the ELB IP sends `Host: 80.158.5.59`, which can never match a host rule, so that traffic routes to the default server. Use a DNS hostname (e.g. `java-app.local`, or a real domain pointed at the ELB).

7. **The per-status request histogram `nginx_ingress_controller_requests` only populates for host-matched traffic.**
   The ingress-nginx controller exposes `nginx_ingress_controller_nginx_process_requests_total` (total, no status label) for all traffic, but the per-status histogram used by the 4xx alert (`nginx_ingress_controller_requests{status=...}`) is only written for requests whose `Host` header matches a DNS host defined in an Ingress. A hostless catch-all ingress returns 200s for everything, yet the per-status metric stays empty — the 4xx alert is defined and correct but can never fire. Fix: add a DNS host rule (e.g. `host: java-app.local`) so the measurable traffic matches it; keep the hostless catch-all alongside it to preserve raw IP access. Verify with `curl -s -H "Host: java-app.local" http://<ELB-IP>/path-that-doesnt-exist` (a 404) and then query `nginx_ingress_controller_requests{host="java-app.local"}` — both `status="200"` and `status="404"` series appear.

   Note: `java-app.local` is not resolvable by any DNS — browser access to the host-scoped route only works after adding it locally (`echo "80.158.5.59 java-app.local" | sudo tee -a /etc/hosts`); without it, only `curl -H "Host: java-app.local"` works.

## Sending Alert Notifications

Instead of using Slack, a **self-hosted Rocket.Chat** was deployed to the cluster and used as the chat channel (native Alertmanager `rocketchatConfigs` receiver — the deployed Alertmanager is v0.34.0, so no webhook adapter is needed). Email reuses the existing Gmail configuration from the 16-prometheus project.

1. Deployed Rocket.Chat with a single Helm chart (2-pod monolith: Rocket.Chat + MongoDB):
    - `helm repo add rocketchat https://rocketchat.github.io/helm-charts` + `helm repo update`
    - `mise exec -- helm install rocketchat rocketchat/rocketchat -n monitoring -f k8s/rocketchat-values.yaml --set "mongodb.auth.passwords[0]=<app-pass>" --set "mongodb.auth.rootPassword=<root-pass>" --wait --timeout 15m`
    - `k8s/rocketchat-values.yaml` — `microservices.enabled: false` **and** `nats.enabled: false` (see Gotcha 2 below), explicit resources (the chart ships none), `extraSecret: rocketchat-admin` for headless first boot (`ADMIN_USERNAME`/`ADMIN_EMAIL`/`ADMIN_PASS` env vars create the admin user and mark the setup wizard completed — the whole setup is then API-driven, no browser), `mongodb.image.tag: "8.0.13"` (RC 8.6.1 requires Mongo ≥ 8.0), `mongodb.persistence.storageClass: csi-disk`
    - browser access is via `kubectl port-forward` (dev); Alertmanager talks to Rocket.Chat in-cluster at `http://rocketchat-rocketchat.monitoring.svc:80`

    Verified: `mise exec -- kubectl -n monitoring get pods` → `rocketchat-rocketchat-*` 1/1 + `rocketchat-mongodb-0` 2/2, 0 restarts, **no NATS pods**; PVC `Bound` on `csi-disk`; port-forward → `/health` 200 and admin login `success`.

1. Created the `#dev-alerts` channel and the Alertmanager credentials **via the Rocket.Chat API**: `POST /api/v1/login` → `POST /api/v1/channels.create` → `POST /api/v1/users.generatePersonalAccessToken`. The PAT + admin userId are stored in the `rocketchat-auth` Secret (keys `token`, `token_id`) — values live in the cluster only, never in the repo (`k8s/rocketchat-secret.yaml` is a placeholder). Verified with a test `POST /api/v1/chat.postMessage` using the PAT.

1. For email, `k8s/email-secret.yaml` committed as the placeholder manifest; adjusted with actual value and applied.

1. Created `k8s/alertmanager-config.yaml` (`AlertmanagerConfig` CRD in `monitoring`), routing on the `app` label the exercise alerts already carry:

    | Route | Matchers | Receiver |
    |-------|----------|----------|
    | Java / MySQL | `app=~"java-app\|mysql"` | `rocketchat` → `#dev-alerts` |
    | Nginx / K8s | `app=~"nginx-ingress\|kubernetes"` | `email` → Gmail (`smtp.gmail.com:587`, `gmail-auth` secret) |
    | Catch-all | (no matchers) | `email` — unmatched alerts (e.g. the built-in kube rules) are never silently dropped |

    Both receivers have `sendResolved: true`. The CRD matchers use the object form (`name`/`value`/`matchType: "=~"`), and OR is expressed as a single regex matcher with `|` (matchers in a list are AND-ed).

1. Fixed the Alertmanager **matcher strategy** so alerts are not silently dropped: kube-prometheus-stack defaults to `OnNamespace`, which makes the operator inject a `namespace=<CR namespace>` matcher into the first route — the exercise alerts carry `app`/`severity` but no `namespace` label, so every alert would be filtered out with no error. Set `alertmanager.alertmanagerConfigMatcherStrategy.type: None` in `k8s/monitoring-values.yaml` and applied with a **version-pinned** upgrade:
    - `helm upgrade monitoring prometheus-community/kube-prometheus-stack -n monitoring --version 90.0.0 -f k8s/monitoring-values.yaml --reuse-values --wait`
    - `mise exec -- kubectl apply -f k8s/alertmanager-config.yaml`

    Verified: `kubectl -n monitoring get alertmanagerconfig` → `app-notifications`; Alertmanager logs show "Completed loading of configuration file"; `/api/v2/status` on the Alertmanager service shows both receivers and both child routes in the generated config.

1. Verified end-to-end (1 alert per channel):
    - **Email**: a burst of host-scoped 404s (`curl -H "Host: java-app.local" http://80.158.5.59/path-that-doesnt-exist`) drove `NginxIngressHigh4xxRatio` to firing → **email arrived in the Gmail inbox**; 1200 clean 200s then diluted the ratio back under 5% and the alert resolved
    - **Chat**: a ~15 req/s load for 4 min (`/get-data`) drove `JavaAppTooManyRequests` to firing → **message appeared in `#dev-alerts`** (title `🚨 FIRING: JavaAppTooManyRequests`, body with summary + description); the load decayed and the **RESOLVED** message followed
    - routing split held: Java/MySQL alerts appear in the channel only, Nginx/K8s alerts in email only
    - final state: all 5 exercise alerts `state: inactive`, `health: ok`; only the built-in `Watchdog` active in Alertmanager

### Gotchas

1. **The `OnNamespace` matcher strategy silently drops all configured alerts.** kube-prometheus-stack's default `alertmanagerConfigMatcherStrategy` is `OnNamespace`: the operator injects a `namespace=<AlertmanagerConfig namespace>` matcher into the first route, so an AlertmanagerConfig only routes alerts that carry that `namespace` label. Our alerts carry `app`/`severity` but no `namespace` → nothing is ever routed, and there is no error anywhere. Fix: `alertmanager.alertmanagerConfigMatcherStrategy.type: None` in the helm values (persistent across upgrades).

2. **The Rocket.Chat chart deploys NATS even with `microservices.enabled: false`.** The values.yaml comment claiming "monolith RC without NATS" is stale: the nats subchart condition is `nats.enabled, microservices.enabled` and `nats.enabled` defaults to nil, which is treated as *enabled* — so 2 NATS pods + nats-box get deployed regardless. Fix: set `nats.enabled: false` explicitly.

3. **Rocket.Chat 8.6.1 requires MongoDB ≥ 8.0; the chart pins 6.0.10.** RC exits at boot with `YOUR CURRENT MONGODB VERSION IS NOT SUPPORTED`. Fix: override `mongodb.image.tag: "8.0.13"` (same `bitnamilegacy/mongodb` repo family). If a failed first attempt already wrote a 6.0 data directory, delete the PVC and reinstall — 6.0 → 8.0 is not an in-place upgrade (it would skip 7.0).

4. **No default StorageClass in the cluster → the Mongo PVC stays Pending → RC crash-loops with `Topology is closed`.** The chart's Mongo PVC sets no `storageClassName`; without a default StorageClass the PVC fails to bind (`no persistent volumes available for this claim and no storage class is set`), Mongo never starts, and RC keeps failing to create indexes against a closed connection during first boot. Fix: `mongodb.persistence.storageClass: csi-disk`. Note: StatefulSet `volumeClaimTemplates` are **immutable**, so a fix after the fact requires uninstall + delete the orphaned PVC + reinstall (safe here — RC had never started, no data).

5. **`helm upgrade` without `--version` drifted kube-prometheus-stack 90.0.0 → 91.4.1 and caused 3 false alerts** (a second occurrence of the `helm upgrade` version-drift gotcha from the previous section). The newer chart's built-in rules use `absent(up{job="kube-scheduler"|"kube-proxy"|"kube-controller-manager"})`; on a managed CCE control plane those jobs have **zero scrape targets** (no pods to scrape — the chart's synthetic services have no endpoints), so `absent()` = 1 and `KubeSchedulerDown`/`KubeProxyDown`/`KubeControllerManagerDown` all fired. They carry no `app` label, so they fell through to the catch-all route and went to email. (Alertmanager showed 4 active alerts at the time — the 3 above plus the always-on `Watchdog` canary, which is unrelated to the drift.) Fix: re-upgrade pinned at `--version 90.0.0` (the `-f k8s/monitoring-values.yaml --reuse-values` kept the matcher-strategy fix); all 3 `Kube*Down` alerts cleared (`Watchdog` stays active by design).

6. **Go templates in the AlertmanagerConfig: `\n` escapes are not processed — you need real newlines.** A `text` template written as `'line1\nline2'` renders the literal characters `\n` in the message. Fix: use a YAML block scalar (`text: |-`) so the template contains actual newline characters.

7. **The `rocketchatConfigs` fields are strict — the CRD rejects unknown fields.** `username` is not a field (`unknown field "spec.receivers[0].rocketchatConfigs[0].username"`). Also, `apiURL` is a **plain string** (pattern `^https?://.+$`), not a SecretKeySelector — the in-cluster `http://rocketchat-rocketchat.monitoring.svc:80` goes inline (non-sensitive); only `token` and `tokenID` are SecretKeySelectors.

8. **Resetting the admin password: `rc-password` hangs in the RC image.** Running `node /app/bundle/main.js rc-password <user> <pass>` inside the pod hangs indefinitely with no output. What worked: delete the admin user from Mongo directly (`db.users.deleteMany({username: "admin"})` + `db.meteor_accounts_password_login_solutions.deleteMany({})` via `mongosh` inside the mongo pod), then restart the RC pod so the `ADMIN_*` env-var bootstrap recreates the admin with the current password. (The bootstrap only runs while no admin user exists — once an admin exists, `ADMIN_PASS` is ignored, which is why the reset is needed if the secret's password changed after first boot.)

