# Shared helpers, sourced by deploy.sh / verify.sh / teardown.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

RELEASE="alloy-atlas"
SECRET="alloy-atlas-secrets"
CHART_VERSION="${CHART_VERSION:-1.16.0}"   # grafana/alloy chart, pinned for reproducibility

die() { echo "ERROR: $*" >&2; exit 1; }

load_env() {
  [[ -f .env ]] || die ".env not found. Run: cp .env.example .env  and fill it in."
  set -a; source .env; set +a
  local missing=()
  for v in ATLAS_PROM_USER ATLAS_PROM_PASSWORD PROM_REMOTE_WRITE_URL PROM_USER PROM_PASSWORD; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "empty in .env: ${missing[*]}"
  [[ "$ATLAS_PROM_USER" == prom_user_* ]] || die "ATLAS_PROM_USER should look like prom_user_<atlas project id>"
  NS="${K8S_NAMESPACE:-alloy-atlas}"
  CTX="${K8S_CONTEXT:-$(kubectl config current-context)}"
  KUBECTL=(kubectl --context "$CTX")
}

need() { command -v "$1" >/dev/null || die "missing required tool: $1"; }
