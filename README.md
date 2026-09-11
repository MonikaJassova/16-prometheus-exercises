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
