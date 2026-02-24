#!/bin/bash
set -e

# ============================================
# KONFIGURACJA
# ============================================
RESOURCE_GROUP="rg-devops-poc01"
CLUSTERS=("devops-poc01-test" "devops-poc01-prod")
CLUSTER_TEST="devops-poc01-test"
VALUES_FILE="charts/app-of-apps/values.yaml"
# GitHub App secrets are managed via External Secrets Operator (Azure Key Vault)
# Template file (no real keys): bootstrap/argocd-repositories-github-app.yaml
INGRESS_APP="bootstrap/ingress-nginx.yaml"
MON_NS="monitoring"
SECRET_NAME="alertmanager-gmail"

# Timeouty (w sekundach)
TIMEOUT_INGRESS_IP=600
TIMEOUT_NAMESPACE=300
TIMEOUT_ARGOCD_SYNC=600

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================
# FUNKCJE POMOCNICZE
# ============================================

# Wyświetl banner
show_banner() {
  echo -e "${MAGENTA}"
  echo "╔════════════════════════════════════════════╗"
  echo "║   UNIWERSALNY SKRYPT WDROŻENIOWY v2.0     ║"
  echo "║   Platform Bootstrap & Configuration      ║"
  echo "╚════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# Sprawdź czy plik istnieje
check_file() {
  local file="$1"
  local name="$2"
  
  if [ ! -f "$file" ]; then
    echo -e "${RED}❌ Błąd: Nie znaleziono $name: $file${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ Znaleziono: $name${NC}"
}

# Czekaj na zasób z timeoutem
wait_for_resource() {
  local description="$1"
  local command="$2"
  local timeout="$3"
  
  echo -e "⏳ ${description}..."
  local elapsed=0
  
  until eval "$command" >/dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
      echo -e "\n${RED}❌ Timeout po ${timeout}s!${NC}"
      return 1
    fi
    echo -n "."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  
  echo -e "\n${GREEN}✓ ${description} - OK${NC}"
  return 0
}

# Sprawdź czy ArgoCD jest zainstalowany
check_argocd() {
  local cluster="$1"
  
  if ! kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
    echo -e "${RED}❌ ArgoCD nie jest zainstalowany na klastrze: ${cluster}${NC}"
    echo "   Zainstaluj ArgoCD przed uruchomieniem tego skryptu"
    return 1
  fi
  echo -e "${GREEN}✓ ArgoCD jest zainstalowany${NC}"
  return 0
}

# ============================================
# GŁÓWNY SKRYPT
# ============================================

show_banner

echo -e "${CYAN}════════════════════════════════════════════${NC}"
echo -e "${CYAN}Sprawdzanie wymaganych plików...${NC}"
echo -e "${CYAN}════════════════════════════════════════════${NC}\n"

check_file "$VALUES_FILE" "values.yaml"
# GitHub App secrets are provisioned via External Secrets Operator (not from file)
check_file "$INGRESS_APP" "Ingress Application"

# ============================================
# KROK 1: INSTALACJA INGRESS & POBRANIE IP
# ============================================
echo -e "\n${YELLOW}════════════════════════════════════════════${NC}"
echo -e "${YELLOW}▶ KROK 1: Instalacja Ingress-NGINX${NC}"
echo -e "${YELLOW}════════════════════════════════════════════${NC}\n"

echo "🔗 Łączenie z klastrem TEST: ${CLUSTER_TEST}"
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_TEST}" \
  --admin \
  --overwrite-existing >/dev/null

echo -e "${GREEN}✓ Połączono z klastrem${NC}"

# Sprawdź czy ArgoCD jest zainstalowany
check_argocd "${CLUSTER_TEST}" || exit 1

echo ""
echo "🚀 Aplikowanie ArgoCD Application dla Ingress..."
kubectl apply -f "$INGRESS_APP"

echo ""
echo "⏳ Czekam na LoadBalancer IP..."
INGRESS_IP=""
elapsed=0

while [ -z "$INGRESS_IP" ] && [ $elapsed -lt $TIMEOUT_INGRESS_IP ]; do
  INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  
  if [ -z "$INGRESS_IP" ]; then
    echo -n "."
    sleep 10
    elapsed=$((elapsed + 10))
  fi
done

echo ""

if [ -z "$INGRESS_IP" ]; then
  echo -e "${RED}❌ Timeout! Nie uzyskano IP po ${TIMEOUT_INGRESS_IP}s${NC}"
  echo "Sprawdź status: kubectl get svc -n ingress-nginx"
  exit 1
fi

echo -e "${GREEN}✅ Uzyskano LoadBalancer IP: ${INGRESS_IP}${NC}"

# ============================================
# KROK 2: AKTUALIZACJA VALUES.YAML
# ============================================
echo -e "\n${YELLOW}════════════════════════════════════════════${NC}"
echo -e "${YELLOW}▶ KROK 2: Aktualizacja values.yaml${NC}"
echo -e "${YELLOW}════════════════════════════════════════════${NC}\n"

# Backup
BACKUP_FILE="${VALUES_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
echo "📦 Tworzę backup: $BACKUP_FILE"
cp "$VALUES_FILE" "$BACKUP_FILE"

# Pokazanie obecnego stanu
echo ""
echo -e "${BLUE}📊 Obecny stan aplikacji:${NC}"
echo "────────────────────────────────────────────"
grep -A 3 "dependencyTrack:" "$VALUES_FILE" | grep "enabled:" | head -1 | sed 's/^/  DependencyTrack: /'
grep -A 3 "sonarqube:" "$VALUES_FILE" | grep "enabled:" | head -1 | sed 's/^/  SonarQube:       /'
grep -A 3 "prometheus:" "$VALUES_FILE" | grep "enabled:" | head -1 | sed 's/^/  Prometheus:      /'
grep -A 3 "alertmanager:" "$VALUES_FILE" | grep "enabled:" | head -1 | sed 's/^/  Alertmanager:    /'

# Aktualizacja pliku - TYLKO DependencyTrack (enabled + hostname)
echo ""
echo "🔄 Aktualizuję values.yaml (tylko DependencyTrack)..."

awk -v new_ip="$INGRESS_IP" '
BEGIN { 
  in_dt = 0
}

# Wykryj dependencyTrack (dowolne wcięcie)
/dependencyTrack:/ { 
  in_dt = 1
  print
  next
}

# Koniec sekcji - kolejna aplikacja na tym samym poziomie (prometheus/sonarqube/alertmanager)
in_dt == 1 && /^[[:space:]]*(prometheus|sonarqube|alertmanager):/ { 
  in_dt = 0 
}

# W sekcji DT - zmień enabled: false na true (tylko pierwsza wartość enabled po dependencyTrack)
in_dt == 1 && /^[[:space:]]*enabled: false/ && !dt_enabled_done {
  sub(/enabled: false/, "enabled: true")
  dt_enabled_done = 1
  print
  next
}

# W sekcji DT - zmień hostname z nip.io
in_dt == 1 && /hostname:/ && /nip\.io/ {
  sub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, new_ip)
  print
  next
}

{ print }
' "$VALUES_FILE" > "${VALUES_FILE}.tmp"

mv "${VALUES_FILE}.tmp" "$VALUES_FILE"

# Weryfikacja zmian
echo ""
echo "🔍 Weryfikuję zmiany..."
DT_ENABLED=$(grep -A 5 "dependencyTrack:" "$VALUES_FILE" | grep "enabled:" | head -1 | grep -o "true\|false")
DT_HOSTNAME=$(grep -A 20 "dependencyTrack:" "$VALUES_FILE" | grep "hostname:" | head -1 | grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+")

if [[ "$DT_ENABLED" == "true" ]]; then
  echo -e "${GREEN}✓ DependencyTrack enabled: true${NC}"
else
  echo -e "${RED}✗ DependencyTrack enabled: ${DT_ENABLED} (powinno być true)${NC}"
fi

if [[ "$DT_HOSTNAME" == "$INGRESS_IP" ]]; then
  echo -e "${GREEN}✓ DependencyTrack hostname: dependency-track.${INGRESS_IP}.nip.io${NC}"
else
  echo -e "${RED}✗ DependencyTrack hostname IP: ${DT_HOSTNAME} (powinno być ${INGRESS_IP})${NC}"
fi

# Info o backupie (bez git diff)
echo ""
echo -e "${CYAN}ℹ️  Backup utworzony: $BACKUP_FILE${NC}"

# ============================================
# KONTROLA GIT
# ============================================
echo ""
echo -e "${YELLOW}════════════════════════════════════════════${NC}"
echo -e "${YELLOW}⏸️  PUNKT KONTROLNY: Git Push${NC}"
echo -e "${YELLOW}════════════════════════════════════════════${NC}\n"

echo -e "${CYAN}📤 Wykonaj teraz ręcznie:${NC}"
echo ""
echo "  git add $VALUES_FILE"
echo "  git commit -m 'feat: Enable DependencyTrack with IP ${INGRESS_IP}'"
echo "  git push"
echo ""
echo -e "${YELLOW}⚠️  WAŻNE: Poczekaj aż push się zakończy przed kontynuacją!${NC}"
echo ""

# Pętla czekająca na potwierdzenie
while true; do
  read -p "Czy wypchnąłeś już zmiany do origin? (wpisz 'tak'): " CONFIRM
  
  if [[ "$CONFIRM" == "tak" ]]; then
    echo ""
    echo "🔍 Weryfikuję push do origin..."
    
    # Fetch najnowszych zmian z origin
    if git fetch origin >/dev/null 2>&1; then
      LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
      REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "")
      
      if [[ -n "$LOCAL" && -n "$REMOTE" && "$LOCAL" == "$REMOTE" ]]; then
        echo -e "${GREEN}✅ Push zweryfikowany! Commit na origin.${NC}"
        break
      else
        echo -e "${RED}❌ Commit lokalny nie jest jeszcze na origin!${NC}"
        echo "   Local HEAD:  $LOCAL"
        echo "   Remote HEAD: $REMOTE"
        echo ""
        echo "   Wykonaj: git push"
        echo ""
      fi
    else
      echo -e "${YELLOW}⚠️  Nie można zweryfikować - kontynuuję...${NC}"
      break
    fi
  else
    echo -e "${YELLOW}Wpisz 'tak' aby kontynuować (po wykonaniu push)${NC}"
  fi
done

echo ""

# ============================================
# KROK 3 & 4: BOOTSTRAP KLASTRÓW
# ============================================
echo ""
echo -e "${YELLOW}════════════════════════════════════════════${NC}"
echo -e "${YELLOW}▶ KROK 3 & 4: Bootstrap Klastrów${NC}"
echo -e "${YELLOW}════════════════════════════════════════════${NC}\n"

for CLUSTER in "${CLUSTERS[@]}"; do
  echo ""
  echo -e "${BLUE}────────────────────────────────────────────${NC}"
  echo -e "${BLUE}  🔗 Klaster: ${CLUSTER}${NC}"
  echo -e "${BLUE}────────────────────────────────────────────${NC}"
  
  # Połączenie z klastrem
  echo "→ Łączenie z klastrem..."
  az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER}" \
    --admin \
    --overwrite-existing >/dev/null
  
  echo -e "${GREEN}✓ Połączono${NC}"
  
  # Sprawdź ArgoCD
  check_argocd "${CLUSTER}" || continue
  
  # GitHub App Secrets - managed via External Secrets Operator
  echo ""
  echo "→ Sprawdzanie External Secrets Operator..."
  if kubectl get deployment -n external-secrets external-secrets &>/dev/null; then
    echo -e "${GREEN}✓ External Secrets Operator jest zainstalowany${NC}"
    echo "→ Aplikowanie ClusterSecretStore i ExternalSecrets..."
    kubectl apply -f "bootstrap/external-secrets-config.yaml"
    echo -e "${GREEN}✓ ExternalSecrets skonfigurowane - sekrety będą pobierane z Azure Key Vault${NC}"
  else
    echo -e "${YELLOW}⚠️  External Secrets Operator nie jest jeszcze zainstalowany${NC}"
    echo "   Zostanie zainstalowany przez ArgoCD app-of-apps. Po instalacji uruchom ponownie skrypt."
  fi

  # Sprawdź czy sekrety ArgoCD repo są dostępne
  echo ""
  echo "→ Sprawdzanie GitHub App Secrets..."
  if kubectl get secret repo-platform-apps -n argocd &>/dev/null; then
    echo -e "${GREEN}✓ GitHub App Secrets obecne w klastrze${NC}"
  else
    echo -e "${YELLOW}⚠️  Brak GitHub App Secrets w namespace argocd${NC}"
    echo "   Poczekaj aż External Secrets zsynchronizuje sekrety z Key Vault."
  fi
  
  # Określ właściwy bootstrap file
  BOOTSTRAP="bootstrap/app-of-apps-prod.yaml"
  ROOT_NAME="platform-apps-prod"
  
  if [[ "${CLUSTER}" == "$CLUSTER_TEST" ]]; then
    BOOTSTRAP="bootstrap/app-of-apps-test.yaml"
    ROOT_NAME="platform-apps-test"
  fi
  
  if [ ! -f "$BOOTSTRAP" ]; then
    echo -e "${RED}❌ Nie znaleziono: $BOOTSTRAP${NC}"
    continue
  fi
  
  # Aplikuj root Application
  echo ""
  echo "→ Aplikowanie root Application: ${BOOTSTRAP}"
  kubectl apply -f "${BOOTSTRAP}"
  
  # Czekaj na synchronizację
  echo ""
  echo "⏳ Czekam na synchronizację ArgoCD..."
  
  elapsed=0
  until kubectl -n argocd get application "${ROOT_NAME}" -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q "Synced"; do
    if [ $elapsed -ge $TIMEOUT_ARGOCD_SYNC ]; then
      echo -e "\n${YELLOW}⚠️ Timeout synchronizacji po ${TIMEOUT_ARGOCD_SYNC}s${NC}"
      break
    fi
    echo -n "."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  
  echo ""
  
  # Status synchronizacji
  SYNC_STATUS=$(kubectl -n argocd get app "${ROOT_NAME}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "unknown")
  HEALTH_STATUS=$(kubectl -n argocd get app "${ROOT_NAME}" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "unknown")
  
  echo -e "${CYAN}→ Sync status:   ${SYNC_STATUS}${NC}"
  echo -e "${CYAN}→ Health status: ${HEALTH_STATUS}${NC}"
  
  # Lista child Applications
  echo ""
  echo "→ Child Applications:"
  kubectl -n argocd get applications.argoproj.io -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || echo "Brak aplikacji"
  
  echo -e "${GREEN}✅ Klaster ${CLUSTER} - bootstrap zakończony${NC}"
done

# ============================================
# KROK 5: OBSERVABILITY (TYLKO TEST)
# ============================================
echo ""
echo -e "${YELLOW}════════════════════════════════════════════${NC}"
echo -e "${YELLOW}▶ KROK 5: Konfiguracja Observability${NC}"
echo -e "${YELLOW}════════════════════════════════════════════${NC}\n"

echo "🔗 Łączenie z klastrem TEST..."
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_TEST}" \
  --admin \
  --overwrite-existing >/dev/null

# Czekaj na namespace monitoring
echo ""
if ! wait_for_resource "Czekam na namespace ${MON_NS}" \
  "kubectl get ns ${MON_NS}" \
  $TIMEOUT_NAMESPACE; then
  echo -e "${RED}❌ Namespace ${MON_NS} nie powstał${NC}"
  echo "   Sprawdź ArgoCD: kubectl get applications -n argocd"
  exit 1
fi

# Sprawdź i utwórz secret Gmail
echo ""
if kubectl get secret -n "${MON_NS}" "${SECRET_NAME}" >/dev/null 2>&1; then
  echo -e "${YELLOW}ℹ️  Secret ${SECRET_NAME} już istnieje - pomijam${NC}"
else
  echo -e "${CYAN}📧 Konfiguracja Gmail App Password dla Alertmanager${NC}"
  echo ""
  echo "Aby wysyłać alerty, potrzebujesz Gmail App Password:"
  echo "  1. https://myaccount.google.com/apppasswords"
  echo "  2. Utwórz nowe hasło aplikacji"
  echo "  3. Skopiuj 16-znakowy kod"
  echo ""
  
  read -s -p "Podaj Gmail APP PASSWORD: " SMTP_PASS
  echo ""
  
  if [[ -z "$SMTP_PASS" ]]; then
    echo -e "${RED}❌ Hasło nie może być puste${NC}"
    exit 1
  fi
  
  kubectl create secret generic "${SECRET_NAME}" \
    -n "${MON_NS}" \
    --from-literal=smtp_password="${SMTP_PASS}"
  
  echo -e "${GREEN}✅ Secret ${SECRET_NAME} utworzony${NC}"
fi

# ============================================
# KROK 6: NAPRAWA INGRESS (AZURE FIX)
# ============================================
echo ""
echo -e "${YELLOW}════════════════════════════════════════════${NC}"
echo -e "${YELLOW}▶ KROK 6: Optymalizacja Ingress dla Azure${NC}"
echo -e "${YELLOW}════════════════════════════════════════════${NC}\n"

for CLUSTER in "${CLUSTERS[@]}"; do
  echo ""
  echo "🔧 Klaster: ${CLUSTER}"
  
  az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER}" \
    --admin \
    --overwrite-existing >/dev/null
  
  echo "→ Dodawanie adnotacji health probe..."
  kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path="/healthz" \
    --overwrite
  
  echo "→ Restart controllera..."
  kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
  
  echo "→ Czekam na rollout..."
  kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=180s
  
  echo -e "${GREEN}✅ Ingress zoptymalizowany na: ${CLUSTER}${NC}"
done

# ============================================
# FINALNE PODSUMOWANIE
# ============================================
echo ""
echo -e "${MAGENTA}╔════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║                                            ║${NC}"
echo -e "${MAGENTA}║   🎉 WDROŻENIE ZAKOŃCZONE POMYŚLNIE! 🎉   ║${NC}"
echo -e "${MAGENTA}║                                            ║${NC}"
echo -e "${MAGENTA}╚════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}📋 Podsumowanie:${NC}"
echo "────────────────────────────────────────────"
echo "  ✅ Ingress-NGINX zainstalowany"
echo "  ✅ Values.yaml zaktualizowany i wypchnięty"
echo "  ✅ ArgoCD Applications wdrożone"
echo "  ✅ Observability skonfigurowane"
echo "  ✅ Azure Load Balancer zoptymalizowany"
echo ""

echo -e "${CYAN}🌐 Dostępne usługi:${NC}"
echo "────────────────────────────────────────────"
echo "  📊 DependencyTrack:"
echo "     http://dependency-track.${INGRESS_IP}.nip.io"
echo "     (admin / admin)"
echo ""
echo "  🔍 SonarQube:"
echo "     kubectl get svc -n sonarqube"
echo ""
echo "  📈 Prometheus & Alertmanager:"
echo "     kubectl get svc -n monitoring"
echo ""

echo -e "${CYAN}📊 Monitoring:${NC}"
echo "────────────────────────────────────────────"
echo "  kubectl get applications -n argocd"
echo "  kubectl get pods -A"
echo "  kubectl get ingress -A"
echo ""

echo -e "${CYAN}📂 Backup:${NC}"
echo "  Values backup: $BACKUP_FILE"
echo ""

echo -e "${GREEN}Happy DevOps! 🚀${NC}"
echo ""