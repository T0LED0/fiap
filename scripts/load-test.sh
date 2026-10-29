#!/usr/bin/env bash
# =============================================================================
# load-test.sh — Teste de Escalabilidade (HPA CPU + KEDA SQS + DynamoDB)
# =============================================================================
# Executa os dois testes exigidos no Requisito 5 / Vídeo de Demonstração FIAP:
#   1. Estresse de CPU no evaluation-service (via 'hey') -> Dispara o HPA
#   2. Injeção em lote (200 eventos) na fila SQS       -> Dispara o KEDA e grava no DynamoDB
#
# Uso:
#   ./load-test.sh [OPÇÕES] [BASE_URL]
#
# Opções:
#   --all         Executa Teste 1 (HPA) e Teste 2 (KEDA SQS) [padrão]
#   --eval-only   Executa apenas o Teste 1 (estresse HTTP no evaluation-service)
#   --sqs-only    Executa apenas o Teste 2 (lote de 200 mensagens no SQS + DynamoDB)
#   -h, --help    Exibe esta ajuda
# =============================================================================

set -euo pipefail

export PATH="/opt/homebrew/bin:$HOME/.rd/bin:/usr/local/bin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${BLUE}  $*${RESET}"; \
            echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════${RESET}"; }
show_cmd() { echo -e "${CYAN}\$ $*${RESET}"; }

NAMESPACE="togglemaster"
MODE="all"
BASE_URL=""

usage() {
  cat <<EOF

${BOLD}Uso:${RESET}
  $(basename "$0") [--all | --eval-only | --sqs-only] [BASE_URL]

${BOLD}Dica para a gravação do vídeo:${RESET}
  Abra um segundo terminal ao lado com:
    watch -n 2 "kubectl get hpa,scaledobject,pods -n togglemaster"

EOF
}

for arg in "$@"; do
  case "$arg" in
    --all)       MODE="all" ;;
    --eval-only) MODE="eval" ;;
    --sqs-only)  MODE="sqs" ;;
    -h|--help)   usage; exit 0 ;;
    http://*|https://*) BASE_URL="${arg%/}" ;;
  esac
done

# ---------------------------------------------------------------------------
# Configurar região padrão AWS
# ---------------------------------------------------------------------------
load_credentials() {
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"
}

# ---------------------------------------------------------------------------
# Descobrir URL do Ingress Load Balancer automaticamente
# ---------------------------------------------------------------------------
discover_base_url() {
  if [[ -n "$BASE_URL" ]]; then
    return
  fi

  info "Buscando endereço do Traefik Gateway / Ingress Load Balancer no namespace '${NAMESPACE}'..."
  local lb_host
  lb_host="$(kubectl get ingress togglemaster-ingress -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")"
  if [[ -z "$lb_host" ]]; then
    lb_host="$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")"
  fi
  if [[ -z "$lb_host" ]]; then
    lb_host="$(kubectl get ingress togglemaster-ingress -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")"
  fi

  if [[ -n "$lb_host" ]]; then
    BASE_URL="http://${lb_host}"
    success "Ingress detectado: ${BASE_URL}"
  else
    error "Não foi possível detectar o Ingress automaticamente. Passe a URL como argumento: ./load-test.sh http://<LB_DNS>"
  fi
}

# ---------------------------------------------------------------------------
# Teste 1: Estresse de CPU no evaluation-service (HPA)
# ---------------------------------------------------------------------------
run_eval_load_test() {
  header "TESTE 1 — Estresse de CPU no evaluation-service (HPA)"
  discover_base_url

  local target="${BASE_URL}/evaluate?user_id=load-test-user&flag_name=dark-mode"
  info "Alvo: ${target}"
  info "Estado inicial do HPA e Pods:"
  show_cmd "kubectl get hpa -n $NAMESPACE"
  kubectl get hpa -n "$NAMESPACE" 2>/dev/null || true
  show_cmd "kubectl get pods -n $NAMESPACE -l app=evaluation-service"
  kubectl get pods -n "$NAMESPACE" -l app=evaluation-service 2>/dev/null || true
  echo ""

  info "Disparando teste de estresse contínuo por 25 segundos (30 conexões simultâneas)..."
  if command -v hey &>/dev/null; then
    show_cmd "hey -z 25s -c 30 '$target'"
    hey -z 25s -c 30 "$target"
  elif command -v ab &>/dev/null; then
    show_cmd "ab -r -k -t 25 -c 30 '$target'"
    ab -r -k -t 25 -c 30 "$target" || true
  else
    error "Nenhuma ferramenta de carga ('hey' ou 'ab') encontrada."
  fi

  info "Aguardando 15 segundos para o Metrics Server coletar o pico de CPU e acionar o HPA..."
  sleep 15

  echo ""
  info "Estado do HPA e Pods após o teste de carga:"
  show_cmd "kubectl get hpa -n $NAMESPACE"
  kubectl get hpa -n "$NAMESPACE" 2>/dev/null || true
  show_cmd "kubectl get pods -n $NAMESPACE -l app=evaluation-service"
  kubectl get pods -n "$NAMESPACE" -l app=evaluation-service 2>/dev/null || true
  success "Teste 1 concluído!"
}

# ---------------------------------------------------------------------------
# Teste 2: Injeção em Lote no SQS (KEDA) + Validação no DynamoDB
# ---------------------------------------------------------------------------
run_sqs_batch_test() {
  header "TESTE 2 — Injeção em Lote na Fila SQS (KEDA) & DynamoDB"

  local sqs_url=""
  sqs_url="$(kubectl get configmap togglemaster-config -n "$NAMESPACE" -o jsonpath='{.data.AWS_SQS_URL}' 2>/dev/null || echo "")"
  if [[ -z "$sqs_url" || "$sqs_url" == *"000000000000"* ]]; then
    sqs_url="$(aws sqs get-queue-url --queue-name togglemaster-events --region "$AWS_DEFAULT_REGION" --query 'QueueUrl' --output text 2>/dev/null || echo "")"
  fi

  [[ -n "$sqs_url" ]] || error "Não foi possível obter a URL da fila SQS 'togglemaster-events'."
  info "Fila SQS: ${sqs_url}"

  local count_before
  show_cmd "aws dynamodb scan --table-name ToggleMasterAnalytics --region $AWS_DEFAULT_REGION --select COUNT"
  count_before="$(aws dynamodb scan --table-name ToggleMasterAnalytics --region "$AWS_DEFAULT_REGION" --select "COUNT" --query "Count" --output text 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  info "Itens na tabela DynamoDB 'ToggleMasterAnalytics' ANTES do lote: ${BOLD}${count_before}${RESET}"

  info "Injetando 200 mensagens em lote (20 batches de 10 mensagens) para acionar o KEDA..."
  show_cmd "aws sqs send-message-batch --queue-url $sqs_url --region $AWS_DEFAULT_REGION --entries '[{\"Id\":\"msg-N\",\"MessageBody\":\"{\\\"user_id\\\":\\\"batch-user-N\\\",\\\"flag_name\\\":\\\"dark-mode\\\",\\\"result\\\":true,...}\"}, ... x10]'   # repetido 20 vezes"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  for batch in $(seq 1 20); do
    local entries="["
    for i in $(seq 1 10); do
      local idx=$(( (batch - 1) * 10 + i ))
      local body="{\\\"user_id\\\":\\\"batch-user-${idx}\\\",\\\"flag_name\\\":\\\"dark-mode\\\",\\\"result\\\":true,\\\"timestamp\\\":\\\"${ts}\\\"}"
      [[ $i -gt 1 ]] && entries+=","
      entries+="{\"Id\":\"msg-${idx}\",\"MessageBody\":\"${body}\"}"
    done
    entries+="]"

    aws sqs send-message-batch \
      --queue-url "$sqs_url" \
      --region "$AWS_DEFAULT_REGION" \
      --entries "$entries" >/dev/null 2>&1
    printf "."
  done
  echo ""
  success "200 mensagens injetadas na fila SQS!"

  info "Aguardando 10 segundos para o KEDA ler a fila SQS e escalar os pods do analytics-service..."
  sleep 10

  echo ""
  info "Estado do ScaledObject, HPA e Pods do analytics-service:"
  show_cmd "kubectl get scaledobject,hpa -n $NAMESPACE"
  kubectl get scaledobject,hpa -n "$NAMESPACE" 2>/dev/null || true
  show_cmd "kubectl get pods -n $NAMESPACE -l app=analytics-service"
  kubectl get pods -n "$NAMESPACE" -l app=analytics-service 2>/dev/null || true

  echo ""
  local count_after
  show_cmd "aws dynamodb scan --table-name ToggleMasterAnalytics --region $AWS_DEFAULT_REGION --select COUNT"
  count_after="$(aws dynamodb scan --table-name ToggleMasterAnalytics --region "$AWS_DEFAULT_REGION" --select "COUNT" --query "Count" --output text 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  success "Itens na tabela DynamoDB 'ToggleMasterAnalytics' APÓS o lote: ${BOLD}${count_after}${RESET} (antes: ${count_before})"

  echo ""
  info "Amostra de registros gravados pelo analytics-service:"
  show_cmd "aws dynamodb scan --table-name ToggleMasterAnalytics --region $AWS_DEFAULT_REGION --limit 3"
  aws dynamodb scan --table-name ToggleMasterAnalytics --region "$AWS_DEFAULT_REGION" --limit 3 --output json 2>/dev/null | head -n 40 || true
}

main() {
  load_credentials
  case "$MODE" in
    eval) run_eval_load_test ;;
    sqs)  run_sqs_batch_test ;;
    all)
      run_eval_load_test
      run_sqs_batch_test
      ;;
  esac
}

main
