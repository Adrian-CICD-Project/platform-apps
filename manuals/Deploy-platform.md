How the script works - Short note
Script Structure (6 steps):
STEP 1: Ingress-NGINX Installation

Connects to the TEST cluster
Applies ArgoCD Application for ingress-nginx
Waits for public IP assignment by Azure Load Balancer
Saves the IP to the $INGRESS_IP variable

STEP 2: Updating values.yaml

Creates a file backup
Using AWK in the dependencyTrack section:

Changes enabled: false -> enabled: true
Updates hostname: with the new IP


Verifies if changes were applied

CHECKPOINT: Git Push

Displays git commit & push instructions
Waits for your confirmation (typing "yes")
Verifies if the commit is on origin (git fetch)

STEP 3 & 4: Cluster Bootstrap via ArgoCD

For each cluster (test/prod):

Checks if External Secrets Operator is installed and applies ClusterSecretStore + ExternalSecret CRDs (bootstrap/external-secrets-config.yaml)
Verifies that GitHub App Secrets are present in the argocd namespace (provisioned via External Secrets from Azure Key Vault)
Applies root Application (app-of-apps-test/prod.yaml)
Waits for ArgoCD synchronization
Displays status and list of child applications

Note: GitHub App secrets are NO LONGER stored in the repository. They are delivered via Azure Key Vault + External Secrets Operator.



STEP 5: Observability Configuration

Waits for monitoring namespace (created by Argo)
Creates Kubernetes Secret with Gmail App Password for Alertmanager
Enables email alert sending

STEP 6: Azure Load Balancer Fix

Adds health probe annotation for ingress on both clusters
Restarts ingress-nginx controller
Fixes Azure LB health check issues

Key Features:
All loops have timeouts (will not hang)
ArgoCD verification before bootstrap
values.yaml backup before changes
Checkpoint for Git push
Colorful output for readability
Result:
Platform with DependencyTrack, SonarQube, Prometheus, and Alertmanager deployed on AKS via GitOps (ArgoCD).