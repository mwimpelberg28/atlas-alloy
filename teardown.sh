#!/usr/bin/env bash
# Remove everything deploy.sh created (release, secret, namespace).
source "$(dirname "$0")/lib.sh"
need kubectl; need helm
NS="${K8S_NAMESPACE:-alloy-atlas}"; CTX="${K8S_CONTEXT:-$(kubectl config current-context)}"
[[ -f .env ]] && { set -a; source .env; set +a; NS="${K8S_NAMESPACE:-$NS}"; CTX="${K8S_CONTEXT:-$CTX}"; }
read -r -p "Delete release '$RELEASE' and namespace '$NS' on context '$CTX'? [y/N] " a
[[ "$a" == [yY] ]] || exit 0
helm uninstall "$RELEASE" --kube-context "$CTX" -n "$NS" || true
kubectl --context "$CTX" delete namespace "$NS" --ignore-not-found
