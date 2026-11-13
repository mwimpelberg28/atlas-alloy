#!/usr/bin/env bash
# Check that Alloy is discovering Atlas targets and sending samples to Grafana Cloud.
source "$(dirname "$0")/lib.sh"
need kubectl; need curl
load_env

PORT="${LOCAL_PORT:-12399}"   # avoid 12345, which a local Alloy often uses
"${KUBECTL[@]}" -n "$NS" rollout status deploy/"$RELEASE" --timeout=120s
"${KUBECTL[@]}" -n "$NS" port-forward deploy/"$RELEASE" "$PORT":12345 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 20); do curl -sf "localhost:$PORT/-/ready" >/dev/null && break; sleep 1; done

echo "Waiting up to 2m for the first scrape + remote_write..."
for _ in $(seq 24); do
  m=$(curl -s "localhost:$PORT/metrics")
  targets=$(echo "$m" | awk '/^prometheus_target_scrape_pool_targets\{/{s+=$NF} END{print s+0}')
  sent=$(echo "$m"    | awk '/^prometheus_remote_storage_samples_total\{/{s+=$NF} END{print s+0}')
  failed=$(echo "$m"  | awk '/^prometheus_remote_storage_samples_failed_total\{/{s+=$NF} END{print s+0}')
  [[ "$sent" -gt 0 ]] && break; sleep 5
done
echo "targets=$targets  samples_sent=$sent  samples_failed=$failed"

errs=$("${KUBECTL[@]}" -n "$NS" logs deploy/"$RELEASE" -c alloy --tail=200 | grep -ciE 'level=(error|warn)' || true)
echo "error/warn log lines: $errs"

if [[ "$targets" -gt 0 && "$sent" -gt 0 && "$failed" -eq 0 ]]; then
  echo "PASS. In Grafana Cloud Explore, run:  up{job=\"mongodb-atlas\"}"
else
  echo "FAIL. Debug: ${KUBECTL[*]} -n $NS logs deploy/$RELEASE -c alloy"
  [[ "$targets" -eq 0 ]] && echo "  0 targets: Atlas needs a running M10+ cluster with the Prometheus integration enabled."
  exit 1
fi
