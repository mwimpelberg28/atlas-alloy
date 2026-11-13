# atlas-alloy

Send **MongoDB Atlas** metrics to **Grafana Cloud** using **Grafana Alloy** running in Kubernetes.

A single Alloy pod discovers your Atlas cluster nodes through Atlas's Prometheus integration, scrapes
each node's `/metrics` endpoint every 60 seconds, and forwards the samples to Grafana Cloud with
Prometheus `remote_write`. Everything is installed and checked with three scripts.

```
 MongoDB Atlas                         Your Kubernetes cluster                       Grafana Cloud
┌────────────────────┐   HTTP SD   ┌────────────────────────────────┐ remote_write ┌──────────────┐
│ Prometheus         │◀────────────│ Alloy (1 replica)              │─────────────▶│ Prometheus / │
│ integration        │   scrape    │  discovery.http                │              │ Mimir        │
│  /discovery        │◀────────────│  -> prometheus.scrape          │              └──────────────┘
│  <node>:27018/metrics│           │  -> prometheus.remote_write    │
└────────────────────┘             └────────────────────────────────┘
```

## Contents
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [What gets deployed](#what-gets-deployed)
- [How it works](#how-it-works)
- [Verifying](#verifying)
- [Scripts](#scripts)
- [Customizing](#customizing)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

## Prerequisites

| Requirement | Details |
|---|---|
| Tools | `kubectl` (pointed at the target cluster), `helm` 3, `curl`, `bash` |
| Atlas cluster | **M10 or larger dedicated cluster, running.** Free/shared tiers (M0, M2, M5) and paused clusters are not exposed to the Prometheus integration; discovery returns an empty list. |
| Atlas Prometheus integration | Enabled on the project: **Project > Integrations > Prometheus**. Atlas generates a username (`prom_user_<project id>`) and a password. **The password is shown once**; resetting it invalidates the previous one. |
| Grafana Cloud | A stack with a Prometheus `remote_write` URL and username, plus an access policy token with the `metrics:write` scope. |

## Quick start

```bash
git clone https://github.com/mwimpelberg28/atlas-alloy.git
cd atlas-alloy

cp .env.example .env     # then fill in the values (see Configuration)
./deploy.sh              # checks Atlas credentials, installs or updates Alloy
./verify.sh              # prints PASS when metrics are flowing
```

Then, in Grafana Cloud **Explore** with your Prometheus data source:

```promql
up{job="mongodb-atlas"}
```

You should see one series per cluster node, each with value `1`.

## Configuration

All settings live in `.env` (git-ignored). Copy `.env.example` and fill in:

| Variable | Description |
|---|---|
| `ATLAS_PROM_USER` | Atlas Prometheus integration username, `prom_user_<atlas project id>` |
| `ATLAS_PROM_PASSWORD` | Atlas Prometheus integration password |
| `PROM_REMOTE_WRITE_URL` | Grafana Cloud push URL, e.g. `https://prometheus-prod-XX-prod-REGION.grafana.net/api/prom/push` (Grafana Cloud > your stack > Prometheus > Details) |
| `PROM_USER` | Grafana Cloud Prometheus username (instance ID) |
| `PROM_PASSWORD` | Grafana Cloud access policy token with `metrics:write` |
| `K8S_NAMESPACE` | Namespace to install into. Default `alloy-atlas` |
| `K8S_CONTEXT` | Optional kubectl context. Defaults to your current context |

The Atlas project ID is **derived from `ATLAS_PROM_USER`**, so there is no separate project ID setting.

Environment overrides for the scripts: `CHART_VERSION` (Helm chart version, default pinned in `lib.sh`)
and `LOCAL_PORT` (port used by `verify.sh`, default `12399`).

## What gets deployed

| Object | Name | Namespace |
|---|---|---|
| Namespace | `alloy-atlas` (configurable) | n/a |
| Secret | `alloy-atlas-secrets` (the five credentials above) | `alloy-atlas` |
| Helm release | `alloy-atlas` (chart `grafana/alloy`, pinned version) | `alloy-atlas` |
| Deployment | `alloy-atlas`, **1 replica** | `alloy-atlas` |
| ConfigMap | Alloy config rendered from `config.alloy` | `alloy-atlas` |
| ServiceAccount, ClusterRole, ClusterRoleBinding, Service | Created by the chart | |

The release is independent of any other Alloy or Grafana Kubernetes Monitoring install on the cluster.

## How it works

`config.alloy` has three components:

1. **`discovery.http "atlas"`** calls
   `https://cloud.mongodb.com/prometheus/v1.0/groups/<project id>/discovery` every 60 seconds with
   basic auth. Atlas returns the current list of cluster nodes, with labels such as `cl_name`,
   `group_name`, `region`, `provider`, `node_type` and `availability_zone`. Targets look like
   `<cluster>-shard-00-00.<id>.mongodb.net:27018`.
2. **`prometheus.scrape "atlas_mongo"`** scrapes `https://<target>/metrics` every 60 seconds, using the
   same basic auth, under `job="mongodb-atlas"`. Because targets come from live discovery, new or
   resized nodes are picked up automatically without redeploying.
3. **`prometheus.remote_write "default"`** sends the samples to Grafana Cloud.

Credentials are read with `sys.env()` from environment variables, which the Helm values inject from the
`alloy-atlas-secrets` Secret (`alloy.envFrom`). No credentials appear in the config or in Helm values.

This is the Alloy equivalent of this Prometheus scrape config:

```yaml
- job_name: "mongodb-atlas"
  scrape_interval: 60s
  metrics_path: /metrics
  scheme: https
  basic_auth: { username: <user>, password: <password> }
  http_sd_configs:
    - url: https://cloud.mongodb.com/prometheus/v1.0/groups/<project id>/discovery
      refresh_interval: 60s
      basic_auth: { username: <user>, password: <password> }
```

## Verifying

`./verify.sh` port-forwards to the Alloy pod and reports:

- `targets`: number of scrape targets (should equal the number of Atlas nodes, e.g. 3 for a replica set)
- `samples_sent` and `samples_failed`: remote_write counters (sent should be above 0, failed should be 0)
- count of error/warn lines in the Alloy log

It exits non-zero on failure. You can also inspect Alloy's UI:

```bash
kubectl -n alloy-atlas port-forward deploy/alloy-atlas 12399:12345
# open http://localhost:12399  (components: discovery.http.atlas, prometheus.scrape.atlas_mongo)
```

## Scripts

| Script | Purpose |
|---|---|
| `deploy.sh` | Pre-flights Atlas (fails clearly on 401/403, warns on 0 targets), creates the namespace and Secret, runs `helm upgrade --install`, restarts the pod so credential changes take effect. Idempotent. |
| `verify.sh` | Waits for the first scrape and remote_write, reports counters and log errors, prints PASS or FAIL. |
| `teardown.sh` | After confirmation, uninstalls the release and deletes the namespace. |
| `lib.sh` | Shared helpers (env loading, validation, pinned chart version). Sourced by the others. |

Other files: `config.alloy` (Alloy pipeline), `values.yaml` (Helm values), `.env.example` (settings
template), `.gitignore` (allowlist: ignores everything except the project files above).

## Customizing

- **Scrape interval or job name:** edit `config.alloy`, then re-run `./deploy.sh`. Atlas updates metrics about once a minute, so intervals below 60s add load without adding data.
- **Extra labels or relabeling:** add `rule` blocks via `prometheus.relabel` between the scrape and `remote_write`, or `external_labels` on the `prometheus.remote_write` block.
- **Multiple Atlas projects:** duplicate the `discovery.http` and `prometheus.scrape` blocks per project with different credentials (add the extra variables to the Secret and `deploy.sh`). Give each scrape a distinct `job_name`.
- **Different Alloy version:** `CHART_VERSION=x.y.z ./deploy.sh`.
- **Resources and scheduling:** add them to `values.yaml` (see the [Alloy chart values](https://github.com/grafana/alloy/tree/main/operations/helm/charts/alloy)).

## Security

- `.env` holds secrets and is excluded by `.gitignore`. Never commit it. The ignore file is an allowlist, so new files are ignored until you opt them in.
- In the cluster, credentials are stored in a Kubernetes Secret. Restrict access to the namespace, and consider encrypting Secrets at rest or using an external secrets operator.
- Use the narrowest credentials possible: an access policy token limited to `metrics:write`, and the Atlas Prometheus user (read-only metrics access).
- If a password is ever exposed, rotate it: reset it in Atlas (Integrations > Prometheus) or Grafana Cloud, update `.env`, and re-run `./deploy.sh`.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `deploy.sh`: `403 ... not enabled` | The Prometheus integration is not enabled on the Atlas project. Enable it under Integrations. |
| `deploy.sh`: `401` | Wrong or stale Prometheus username/password. Each reset invalidates the previous password, so copy the latest. Check `ATLAS_PROM_USER` starts with `prom_user_`. |
| `0 target(s)` / discovery returns `[]` | No running M10+ cluster in the project (free/shared and paused clusters are not exposed), or the cluster is still provisioning (5 to 10 minutes). |
| `verify.sh`: targets > 0, `samples_failed` > 0 | Wrong Grafana Cloud URL or username, or the token lacks `metrics:write`. Check logs: `kubectl -n alloy-atlas logs deploy/alloy-atlas -c alloy`. |
| `verify.sh` cannot connect | The local port is in use (a local Alloy often uses 12345). Set `LOCAL_PORT=12400`. |
| `context "..." does not exist` | `K8S_CONTEXT` in `.env` is not a real kubectl context. Leave it empty to use the current context. |
| Series missing in Grafana | Allow a couple of minutes after deploy. Confirm `up{job="mongodb-atlas"}` and that you are using the right Prometheus data source. |

## Limitations

- Atlas M10+ dedicated clusters only (an Atlas restriction, not an Alloy one).
- Metrics are only those the Atlas Prometheus integration provides (database and host metrics from the MongoDB agent). It does not collect logs or query profiles.
- One replica by design; scaling out would scrape and send duplicate series.
