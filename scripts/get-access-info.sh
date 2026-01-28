#!/usr/bin/env bash
set -euo pipefail

###############################################
# Konfiguracja
###############################################

CONTEXTS=(
  "devops-poc01-test-admin"
  "devops-poc01-prod-admin"
)

ARGOCD_NS="${ARGOCD_NS:-argocd}"
SONAR_NS="${SONAR_NS:-sonarqube}"
DTRACK_NS="${DTRACK_NS:-dependency-track}"
MON_NS="${MON_NS:-monitoring}"

ARGOCD_SVC="${ARGOCD_SVC:-argocd-server}"
SONAR_SVC="${SONAR_SVC:-sonarqube-sonarqube}"
DTRACK_SVC="${DTRACK_SVC:-dependency-track-frontend}"
PROM_SVC="${PROM_SVC:-prometheus-operated}"

echo "=== Informacje dostępu do narzędzi platformy (multi-cluster) ==="
echo "Konteksty: ${CONTEXTS[*]}"
echo

# Pomocnicza funkcja do wyciągania endpointu z Service
get_service_endpoint() {
  local K="$1"
  local ns="$2"
  local svc="$3"

  if ! ${K} -n "$ns" get svc "$svc" >/dev/null 2>&1; then
    echo "NIE ZNALEZIONO Service '$svc' w namespace '$ns'"
    return 1
  fi

  local type
  type="$(${K} -n "$ns" get svc "$svc" -o jsonpath='{.spec.type}')"

  local port
  port="$(${K} -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].port}')"

  case "$type" in
    LoadBalancer)
      local ip host
      ip="$(${K} -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
      host="$(${K} -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
      if [[ -n "$ip" ]]; then
        echo "typ:       LoadBalancer"
        echo "endpoint:  http://$ip:$port"
      elif [[ -n "$host" ]]; then
        echo "typ:       LoadBalancer"
        echo "endpoint:  http://$host:$port"
      else
        echo "typ:       LoadBalancer"
        echo "endpoint:  <EXTERNAL-IP jeszcze pending> (port: $port)"
      fi
      ;;
    NodePort)
      local node_ip node_port
      node_port="$(${K} -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].nodePort}')"
      node_ip="$(${K} get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)"
      if [[ -z "$node_ip" ]]; then
        node_ip="$(${K} get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
      fi
      echo "typ:       NodePort"
      if [[ -n "$node_ip" ]]; then
        echo "endpoint:  http://$node_ip:$node_port"
      else
        echo "endpoint:  <brak ExternalIP noda> (nodePort: $node_port)"
      fi
      ;;
    ClusterIP)
      local cip
      cip="$(${K} -n "$ns" get svc "$svc" -o jsonpath='{.spec.clusterIP}')"
      echo "typ:       ClusterIP"
      echo "clusterIP: $cip"
      echo "port:      $port"
      echo "uwaga:     dostęp tylko z wewnątrz klastra / przez port-forward"
      ;;
    *)
      echo "typ:       $type (sprawdź: kubectl -n $ns get svc $svc -o wide)"
      ;;
  esac
}

for CTX in "${CONTEXTS[@]}"; do
  echo "############################################################"
  echo ">>> KONTEKST: ${CTX}"
  echo "############################################################"

  K="kubectl --context ${CTX}"

  # test połączenia
  if ! ${K} cluster-info >/dev/null 2>&1; then
    echo "⚠ Kontekst '${CTX}' nie działa (brak połączenia). Pomijam."
    echo
    continue
  fi

  echo
  echo "### ArgoCD"
  echo "namespace: ${ARGOCD_NS}"
  echo "service:   ${ARGOCD_SVC}"
  get_service_endpoint "$K" "${ARGOCD_NS}" "${ARGOCD_SVC}" || true

  # hasło admina z secreta
  ARGO_PASS="$(
    ${K} -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
  )"

  echo "login:     admin"
  if [[ -n "$ARGO_PASS" ]]; then
    echo "hasło:     $ARGO_PASS"
  else
    echo "hasło:     <nie udało się odczytać z 'argocd-initial-admin-secret'>"
  fi
  echo

  echo "### SonarQube"
  echo "namespace: ${SONAR_NS}"
  echo "service:   ${SONAR_SVC}"
  get_service_endpoint "$K" "${SONAR_NS}" "${SONAR_SVC}" || true
  echo "login:     admin"
  echo "hasło:     admin (o ile nie zmienione)"
  echo

  echo "### Dependency-Track (frontend)"
  echo "namespace: ${DTRACK_NS}"
  echo "service:   ${DTRACK_SVC}"
  get_service_endpoint "$K" "${DTRACK_NS}" "${DTRACK_SVC}" || true
  echo "login:     admin"
  echo "hasło:     admin (o ile nie zmienione w D-Track)"
  echo

  echo "### Prometheus (kube-prometheus-stack)"
  echo "namespace: ${MON_NS}"
  echo "service:   ${PROM_SVC}"
  get_service_endpoint "$K" "${MON_NS}" "${PROM_SVC}" || true
  echo "auth:      domyślnie brak logowania (bez hasła)"
  echo
done

echo "=== Koniec. Jeśli jakiś Service nie pasuje nazwą, popraw nazwy *_SVC / *_NS na górze skryptu. ==="
