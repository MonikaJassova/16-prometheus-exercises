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
