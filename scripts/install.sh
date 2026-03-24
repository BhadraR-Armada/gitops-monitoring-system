#!/bin/bash
# Move to the parent directory of this script (the project root)
cd "$(dirname "$0")/.."
set -e

if [ -z "$TEAMS_WEBHOOK_URL" ]; then
  echo "----------------------------------------------"
  echo "  Teams Webhook URL Required"
  echo "----------------------------------------------"
  echo "  Please enter your Microsoft Teams incoming"
  echo "  webhook URL (from Teams channel connectors):"
  echo "----------------------------------------------"
  read -rp "Teams Webhook URL: " TEAMS_WEBHOOK_URL
  if [ -z "$TEAMS_WEBHOOK_URL" ]; then
    echo "ERROR: Teams webhook URL is required. Exiting."
    exit 1
  fi
fi

echo "--- 1. Installing ArgoCD ---"
kubectl create namespace argocd || true
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "Waiting for ArgoCD CRDs to be established..."
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s
kubectl apply -n argocd -f manifests/argocd-application.yaml

echo "--- 2. Installing Monitoring Stack ---"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f monitoring/values.yaml --wait

echo "--- 3. Installing prometheus-msteams (Teams Alerting Proxy) ---"
helm repo add prometheus-msteams https://prometheus-msteams.github.io/prometheus-msteams/
helm repo update
helm upgrade --install prometheus-msteams prometheus-msteams/prometheus-msteams \
  --namespace monitoring \
  --set connectors[0].alertmanager="$TEAMS_WEBHOOK_URL" \
  --wait

echo "--- 4. Applying ArgoCD Integration & Alerts ---"
until kubectl get svc argocd-metrics -n argocd > /dev/null 2>&1; do
  echo "Waiting for argocd-metrics service..."
  sleep 5
done
kubectl apply -f manifests/svcmonitor.yaml
kubectl apply -f manifests/prometheus-rules.yaml
kubectl label svc argocd-metrics -n argocd release=monitoring

echo "--- 5. Generating and Applying Grafana Dashboard ---"
kubectl create configmap argocd-status-dashboard \
  --namespace monitoring \
  --from-file=argocd-status.json=./grafana/dashboard.json \
  --dry-run=client -o yaml > manifests/dashboard-configmap.yaml

# Add the required Grafana sidecar label to the generated file
sed -i '/metadata:/a \  labels:\n    grafana_dashboard: "1"' manifests/dashboard-configmap.yaml
kubectl apply -f manifests/dashboard-configmap.yaml

echo "--- Deployment Complete! ---"
echo "--- 6. Access Information ---"
echo "--- ArgoCD Admin Password ---"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
echo "--- Grafana Admin Credentials ---"
GRAFANA_PASS=$(kubectl get secret --namespace monitoring -l app.kubernetes.io/component=admin-secret -o jsonpath="{.items[0].data.admin-password}" | base64 --decode)
echo "User: admin"
echo "Pass: $GRAFANA_PASS"
echo "To access the UIs, run these commands in separate terminals:"
echo "ArgoCD:      kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Prometheus:  kubectl port-forward pod/prometheus-monitoring-kube-prometheus-prometheus-0 -n monitoring 9090:9090"
echo "Grafana:     kubectl port-forward -n monitoring $(kubectl get pod -n monitoring -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=monitoring" -o name) 3000"
echo "AlertManager: kubectl port-forward svc/alertmanager-operated -n monitoring 9093:9093"