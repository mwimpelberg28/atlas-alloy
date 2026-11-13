#!/usr/bin/env bash
# Deploy Alloy (MongoDB Atlas Prometheus scrape -> Grafana Cloud) to a Kubernetes cluster.
# Idempotent: safe to re-run after editing .env, config.alloy or values.yaml.
source "$(dirname "$0")/lib.sh"
need kubectl; need helm; need curl
load_env

# Preflight: Atlas credentials and that the project exposes scrape targets.
GID="${ATLAS_PROM_USER#prom_user_}"
code=$(curl -s -o /tmp/atlas_discovery.$$ -w '%{http_code}' -u "$ATLAS_PROM_USER:$ATLAS_PROM_PASSWORD" \
  "https://cloud.mongodb.com/prometheus/v1.0/groups/$GID/discovery" || true)
case "$code" in
  200) n=$(grep -o '"targets"' /tmp/atlas_discovery.$$ | wc -l | tr -d ' ')
       echo "Atlas discovery OK: $n target(s)"
       [[ "$n" -gt 0 ]] || echo "WARNING: 0 targets. Atlas only exposes M10+ dedicated clusters (not M0/M2/M5), and the cluster must be running." ;;
  401) rm -f /tmp/atlas_discovery.$$; die "Atlas rejected the Prometheus username/password (401). Reset them in Atlas > Integrations > Prometheus." ;;
  403) rm -f /tmp/atlas_discovery.$$; die "Prometheus integration is not enabled on this Atlas project (403)." ;;
  *)   rm -f /tmp/atlas_discovery.$$; die "Unexpected Atlas response: HTTP $code" ;;
esac
rm -f /tmp/atlas_discovery.$$

echo "Cluster context: $CTX   Namespace: $NS"
"${KUBECTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" -n "$NS" create secret generic "$SECRET" \
  --from-literal=ATLAS_PROM_USER="$ATLAS_PROM_USER" \
  --from-literal=ATLAS_PROM_PASSWORD="$ATLAS_PROM_PASSWORD" \
  --from-literal=PROM_REMOTE_WRITE_URL="$PROM_REMOTE_WRITE_URL" \
  --from-literal=PROM_USER="$PROM_USER" \
  --from-literal=PROM_PASSWORD="$PROM_PASSWORD" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null

helm upgrade --install "$RELEASE" grafana/alloy --version "$CHART_VERSION" \
  --kube-context "$CTX" -n "$NS" \
  -f values.yaml \
  --set-file alloy.configMap.content=config.alloy \
  --set-string controller.podAnnotations.config-checksum="$(shasum -a 256 config.alloy | cut -c1-16)" \
  --wait

# Env vars come from the Secret, so restart to pick up changed credentials.
"${KUBECTL[@]}" -n "$NS" rollout restart deploy/"$RELEASE" >/dev/null
"${KUBECTL[@]}" -n "$NS" rollout status deploy/"$RELEASE" --timeout=120s

"${KUBECTL[@]}" -n "$NS" get pods
echo; echo "Next: ./verify.sh"
