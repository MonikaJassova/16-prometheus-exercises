#### This project is for the DevOps bootcamp exercise for

- "Monitoring - Prometheus"

The application runs on port 8080 and exposes metrics on port 8081

## Deploying Own (Java) Application

1. Built the sample Java app and pushed an image to a private DockerHub repo:

    - `mise exec -- gradle build`
    - `podman build -t docker.io/monikajassova/demo-app:java-prometheus .`
    - `podman push docker.io/monikajassova/demo-app:java-prometheus`

1. Provisioned a T Cloud Public CCE cluster (managed K8s) including the MySQL with 2 replicas using Terraform. The infrastructure lives in the sibling [12-terraform-exercises repo](https://github.com/MonikaJassova/terraform-exercises/tree/prometheus-java) under `environments/prometheus/`.

    - initialised and applied it: `mise exec -- terraform -chdir=environments/prometheus init` then `mise exec -- terraform -chdir=environments/prometheus apply --auto-approve`
    - generated a kubeconfig pointing at the cluster's public EIP: `mise exec -- bash generate-kubeconfig.sh prometheus` (writes environments/prometheus/kubeconfig.yaml)
    - mise.toml sets KUBECONFIG to point to the generated file, so `mise exec -- kubectl` and `mise exec -- helm` commands target the CCE cluster

1. Wrote K8s config files for the sample Java app with 3 replicas, Ingress rule, DockerHub and DB Secrets, DB ConfigMap, Nginx Ingress Controller deployment using Helm chart and deployed everything to the cluster:
