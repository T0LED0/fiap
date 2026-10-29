#!/usr/bin/env bash
# =============================================================================
# test-app.sh — Validação dos microsserviços ToggleMaster (Fase 2)
# =============================================================================
# Testa o fluxo E2E através do Ingress Load Balancer do EKS ou host local.
# =============================================================================

set -euo pipefail

export PATH="/opt/homebrew/bin:$HOME/.rd/bin:/usr/local/bin:$PATH"

show_cmd() { echo -e "\033[0;36m\$ $*\033[0m"; }

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

BASE_URL="${1:-}"

if [[ -z "$BASE_URL" ]]; then
  echo "[INFO] Buscando endereço do Load Balancer (Ingress / NLB) dinamicamente..."
  for attempt in $(seq 1 12); do
    # 1. Tenta via objeto Ingress no namespace togglemaster (publicado pelo Traefik)
    INGRESS_HOST=$(kubectl get ingress togglemaster-ingress -n togglemaster -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    # 2. Fallback: Service LoadBalancer do Traefik Controller (namespace traefik)
    if [[ -z "$INGRESS_HOST" ]]; then
      INGRESS_HOST=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    fi
    # 3. Fallback: AWS ELBv2 (NLB/ALB) via AWS CLI
    if [[ -z "$INGRESS_HOST" ]]; then
      INGRESS_HOST=$(aws elbv2 describe-load-balancers --region "$AWS_DEFAULT_REGION" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)
      [[ "$INGRESS_HOST" == "None" || "$INGRESS_HOST" == "null" ]] && INGRESS_HOST=""
    fi
    # 4. Fallback: AWS Classic ELB via AWS CLI
    if [[ -z "$INGRESS_HOST" ]]; then
      INGRESS_HOST=$(aws elb describe-load-balancers --region "$AWS_DEFAULT_REGION" --query 'LoadBalancerDescriptions[0].DNSName' --output text 2>/dev/null || true)
      [[ "$INGRESS_HOST" == "None" || "$INGRESS_HOST" == "null" ]] && INGRESS_HOST=""
    fi

    if [[ -n "$INGRESS_HOST" ]]; then
      BASE_URL="http://${INGRESS_HOST}"
      echo "[INFO] Load Balancer detectado automaticamente: $BASE_URL"
      break
    fi
    echo "[INFO] Aguardando provisionamento do Load Balancer ($attempt/12)..."
    sleep 5
  done

  if [[ -z "$BASE_URL" ]]; then
    echo "❌ Não foi possível detectar o Load Balancer automaticamente."
    exit 1
  fi
fi

BASE_URL="${BASE_URL%/}"

echo "========================================="
echo "   Testador E2E - ToggleMaster Fase 2   "
echo "========================================="
echo "Target URL: $BASE_URL"
echo ""

# Aguarda propagação de DNS do Load Balancer antes de disparar os testes
for i in $(seq 1 18); do
  if curl -s --connect-timeout 3 "${BASE_URL}/evaluate" >/dev/null 2>&1; then
    break
  fi
  echo "[INFO] Aguardando propagação de DNS / resposta do Load Balancer ($i/18)..."
  sleep 5
done

# Obtém a MASTER_KEY dinamicamente do Secret do Kubernetes ou do AWS Secrets Manager
if [[ -z "${MASTER_KEY:-}" ]]; then
  MASTER_KEY=$(kubectl get secret togglemaster-secrets -n togglemaster -o jsonpath='{.data.MASTER_KEY}' 2>/dev/null | base64 -d || true)
fi
if [[ -z "${MASTER_KEY:-}" ]]; then
  MASTER_KEY=$(aws secretsmanager get-secret-value --secret-id fiap-fase2-togglemaster-secrets --region "$AWS_DEFAULT_REGION" --query SecretString --output text 2>/dev/null | grep -o '"MASTER_KEY":"[^"]*' | cut -d'"' -f4 || true)
fi
if [[ -z "${MASTER_KEY:-}" ]]; then
  echo "❌ MASTER_KEY não definida no ambiente e não pôde ser lida do Secret 'togglemaster-secrets' nem do AWS Secrets Manager."
  exit 1
fi

# 0. Mostrar os Pods e o roteamento antes dos testes
echo "0. [kubernetes] Pods e roteamento externo no namespace togglemaster"
if command -v kubectl >/dev/null 2>&1; then
  show_cmd "kubectl get pods,ingress -n togglemaster"
  kubectl get pods,ingress -n togglemaster 2>/dev/null || true
  echo ""
fi

# 1. Gerar API Key no auth-service
echo "1. [auth-service] Gerando chave de API..."
show_cmd "curl -s -X POST ${BASE_URL}/admin/keys -H 'Content-Type: application/json' -H 'Authorization: Bearer ${MASTER_KEY:0:4}****' -d '{\"name\": \"test-key\"}'"
AUTH_RESP=$(curl -s -X POST "${BASE_URL}/admin/keys" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -d '{"name": "test-key"}')
echo "Resposta: $AUTH_RESP"

API_KEY=$(echo "$AUTH_RESP" | grep -o '"key":"[^"]*' | cut -d'"' -f4 || echo "")
if [[ -z "$API_KEY" ]]; then
  echo "❌ Falha ao obter chave de API do auth-service."
  exit 1
fi
echo "API Key obtida: ${API_KEY:0:15}..."
echo ""

# 2. Criar Feature Flag no flag-service
echo "2. [flag-service] Criando feature flag 'dark-mode'..."
show_cmd "curl -s -X POST ${BASE_URL}/flags -H 'Content-Type: application/json' -H 'Authorization: Bearer ${API_KEY:0:8}****' -d '{\"name\": \"dark-mode\", \"is_enabled\": true, \"description\": \"Modo escuro para apps\"}'"
FLAG_RESP=$(curl -s -X POST "${BASE_URL}/flags" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d '{"name": "dark-mode", "is_enabled": true, "description": "Modo escuro para apps"}')
echo "Resposta: $FLAG_RESP"
echo ""

# 3. Criar Regra de Targeting no targeting-service
echo "3. [targeting-service] Criando regra de rollout percentual (100%)..."
show_cmd "curl -s -X POST ${BASE_URL}/rules -H 'Content-Type: application/json' -H 'Authorization: Bearer ${API_KEY:0:8}****' -d '{\"flag_name\": \"dark-mode\", \"is_enabled\": true, \"rules\": {\"type\": \"PERCENTAGE\", \"value\": 100}}'"
RULE_RESP=$(curl -s -X POST "${BASE_URL}/rules" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d '{"flag_name": "dark-mode", "is_enabled": true, "rules": {"type": "PERCENTAGE", "value": 100}}')
echo "Resposta: $RULE_RESP"
echo ""

# 4. Avaliar Flag no evaluation-service (Hot Path via Redis Cache e despacho SQS)
echo "4. [evaluation-service] Avaliando flag 'dark-mode' para o usuário 'user-123'..."
show_cmd "curl -s '${BASE_URL}/evaluate?user_id=user-123&flag_name=dark-mode'"
EVAL_RESP=$(curl -s "${BASE_URL}/evaluate?user_id=user-123&flag_name=dark-mode")
echo "Resposta: $EVAL_RESP"
echo ""

echo "========================================="
echo "✅ Testes concluídos com sucesso!"
echo "🌐 URL para abrir no navegador:"
echo "   ${BASE_URL}/evaluate?user_id=user-123&flag_name=dark-mode"
echo "========================================="
