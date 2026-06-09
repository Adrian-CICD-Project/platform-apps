# Platform Apps – GitOps-managed Platform Services

This repository contains the GitOps configuration for platform services deployed to AKS clusters:

- `devops-poc01-test`
- `devops-poc01-prod`

It uses the **App-of-Apps** pattern in ArgoCD with Helm charts.

The toolset includes:

- **Monitoring (kube-prometheus-stack) – SLIM profile**
  - Prometheus
  - Alertmanager
  - Grafana
  - Prometheus Operator
  - Disabled by default for TEST environment:
    - kube-state-metrics
    - node-exporter
    - admission webhooks

- **SonarQube (SLIM profile for TEST)**  
  Minimal CPU/RAM resources and lightweight PostgreSQL.

- **Dependency-Track (SLIM profile for TEST)**
  Minimal replicas and resources.

- **Grafana (TEST)**
  Standalone chart with preconfigured Prometheus datasource and auto-provisioned
  dashboards from grafana.com (JVM Micrometer 4701, Spring Boot Statistics 11378).
  Exposed via LoadBalancer; admin password generated into the `grafana` secret.

- **Argo Rollouts (PROD only)**
  Controller enabling canary deployments for `adrian-java-app` on the PROD cluster
  (enabled in `values-prod.yaml`, explicitly disabled on TEST).

- **External Secrets Operator**
  Securely delivers secrets from Azure Key Vault to Kubernetes clusters.

> **Helm values merging:** ArgoCD merges the chart's default `values.yaml` with
> `values-prod.yaml` on PROD. Apps that must not run on PROD (SonarQube,
> Dependency-Track, Grafana) are therefore **explicitly disabled** in
> `values-prod.yaml` — do not remove those entries.

This repository ensures repeatable GitOps deployment of platform services.

---

## Repository Structure

```
platform-apps/
├── bootstrap/
│   ├── app-of-apps-test.yaml            # ArgoCD root app (TEST)
│   ├── app-of-apps-prod.yaml            # ArgoCD root app (PROD) → values-prod.yaml
│   ├── argocd-repositories-github-app.yaml  # Template (no secrets!)
│   ├── external-secrets-config.yaml     # ClusterSecretStore + ExternalSecrets
│   └── ingress-nginx.yaml
├── charts/
│   └── app-of-apps/
│       ├── Chart.yaml
│       ├── templates/
│       │   └── applications.yaml        # generates ArgoCD applications
│       ├── values.yaml                  # TEST configuration
│       └── values-prod.yaml             # PRODUCTION configuration
├── scripts/
│   ├── deploy-platform.sh
│   └── get-access-info.sh
├── manuals/
└── README.md
```

---

## Deployment Flow (GitOps)

1. AKS cluster and ArgoCD are provisioned by the **infra-azure** repository (Terraform).
2. ArgoCD runs the root application: `platform-apps-test`
3. The `app-of-apps` chart generates child applications:
   - `monitoring`
   - `sonarqube`
   - `dependency-track`
4. ArgoCD synchronizes applications based on `values.yaml`.

After bootstrap, **no additional kubectl commands are required**.

---

## SLIM Mode – Important Notes

The TEST environment runs on **a single AKS node**.  
To avoid scheduler errors (`Too many pods`), the platform toolset has been optimized.

### Monitoring – SLIM

**Enabled:**
- Prometheus
- Alertmanager
- Grafana
- Operator

**Disabled:**
- kube-state-metrics
- node-exporter
- admission webhooks

### SonarQube – SLIM (TEST)

- `replicaCount: 1`
- Lightweight PostgreSQL
- Reduced CPU/RAM resources

### Dependency-Track – SLIM (TEST)

- Frontend: 1 replica
- API: 1 replica
- Minimal resources
- Persistence disabled

This ensures sufficient capacity for required Prometheus and Alertmanager pods.

---

## Monitoring Reset (Optional)

If monitoring gets stuck (e.g., incomplete Helm deployment):

```bash
kubectl -n monitoring delete job monitoring-kube-prometheus-admission-create --ignore-not-found
kubectl -n monitoring delete deployment monitoring-kube-state-metrics --ignore-not-found
kubectl -n monitoring delete daemonset monitoring-prometheus-node-exporter --ignore-not-found

kubectl -n argocd patch application monitoring \
  --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

After running the above, the monitoring Application will be correctly reconciled with SLIM values.

---

## Exposing Services (TEST)

Services can be exposed externally via LoadBalancer:

- ArgoCD
- SonarQube
- Dependency-Track

The `expose_test_apps.sh` script can automate:

- Patching services
- Retrieving public IP addresses
- Logging into ArgoCD
- Optionally adding GitHub repo

---

## Secrets Management

Secrets (GitHub App keys, tokens) are **never stored in Git**. They are managed via:

1. **Azure Key Vault** — central secret store
2. **External Secrets Operator** — pulls secrets from Key Vault into Kubernetes
3. **ClusterSecretStore + ExternalSecret CRDs** — defined in `bootstrap/external-secrets-config.yaml`

> **Setup guide:** See `infra-azure/docs/key-vault-external-secrets-setup.md`

---

## Credentials and Access (TEST)

| Service          | Username | Password                                                                                              |
| ---------------- | -------- | ----------------------------------------------------------------------------------------------------- |
| ArgoCD           | admin    | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| SonarQube        | admin    | Change default password on first login                                                                |
| Dependency-Track | admin    | Change default password on first login                                                                |

> **Important:** Always change default passwords after first login.

---

## Next Steps (Phase 3)

Already implemented:

- ✅ HTTP 500 alert rule (Prometheus) + email notifications (Alertmanager / Gmail SMTP)
- ✅ Grafana dashboards (JVM Micrometer, Spring Boot Statistics)
- ✅ Argo Rollouts canary on PROD

Possible further expansion:

- Optionally add logging (Elastic / Loki) or tracing (Tempo)
- Argo Rollouts analysis steps (automatic rollback based on Prometheus metrics)

Everything flows through: **Git → ArgoCD → Cluster**

---

## Summary

The **platform-apps** repository provides a complete, repeatable, and lightweight GitOps configuration for essential platform tools.

The SLIM profile ensures full functionality even on a small test environment (1-node AKS), while allowing easy expansion for production.
