#!/usr/bin/env bash
set -e

echo "======================================================="
echo "🔍 Validador Automático do Ambiente Local (ToggleMaster)"
echo "======================================================="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
show_cmd() { echo -e "\033[0;36m\$ $*\033[0m"; }

echo -e "\n[Passo 1/4] Verificando contêineres do Docker Compose..."
# Auto-detecta localização do docker-compose.yml
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_CMD="docker compose -f ${APP_DIR}/docker-compose.yml"

show_cmd "$COMPOSE_CMD ps --status running"
$COMPOSE_CMD ps --status running 2>/dev/null || true
RUNNING_CONTAINERS=$($COMPOSE_CMD ps --status running -q 2>/dev/null | wc -l | tr -d ' ')
if [ "$RUNNING_CONTAINERS" -ge 9 ]; then
    echo -e "${GREEN}✅ Sucesso: Encontrados $RUNNING_CONTAINERS contêineres ativos (esperado: 9).${NC}"
else
    echo -e "${RED}❌ Falha: Apenas $RUNNING_CONTAINERS contêineres ativos. Esperado pelo menos 9.${NC}"
    ERRORS=$((ERRORS + 1))
fi

echo -e "\n[Passo 2/4] Testando endpoints de /health (portas externas 8001 a 8005)..."
# Auto-detect Rancher Desktop no macOS e garante port-forward se necessário
LIMA_SSH_SOCK="$HOME/Library/Application Support/rancher-desktop/lima/0/ssh.sock"
if [ -S "$LIMA_SSH_SOCK" ]; then
    if ! curl -s -m 1 http://localhost:8001/health >/dev/null 2>&1; then
        echo "ℹ️ Detectado Rancher Desktop macOS: configurando port-forwarding transparente..."
        ssh -S "$LIMA_SSH_SOCK" -O forward \
            -L 8001:127.0.0.1:8001 -L 8002:127.0.0.1:8002 \
            -L 8003:127.0.0.1:8003 -L 8004:127.0.0.1:8004 \
            -L 8005:127.0.0.1:8005 -L 5432:127.0.0.1:5432 \
            -L 5433:127.0.0.1:5433 -L 6379:127.0.0.1:6379 \
            -L 4566:127.0.0.1:4566 dummy 2>/dev/null || true
    fi
fi
PORTS=("8001" "8002" "8003" "8004" "8005")
NAMES=("auth-service" "flag-service" "targeting-service" "evaluation-service" "analytics-service")

for i in "${!PORTS[@]}"; do
    PORT="${PORTS[$i]}"
    NAME="${NAMES[$i]}"
    show_cmd "curl -s -o /dev/null -w '%{http_code}' http://localhost:${PORT}/health"
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:${PORT}/health" || echo "000")
    if [ "$STATUS" == "200" ]; then
        echo -e "${GREEN}✅ $NAME (localhost:$PORT/health): HTTP $STATUS OK${NC}"
    else
        echo -e "${RED}❌ $NAME (localhost:$PORT/health): Inacessível ou HTTP $STATUS${NC}"
        ERRORS=$((ERRORS + 1))
    fi
done

echo -e "\n[Passo 3/4] Testando fluxo funcional integrado (Auth -> Flag -> Targeting -> Evaluation)..."

# 1. Gerar API Key (lê MASTER_KEY do .env local ou ambiente, com fallback para o default do docker-compose)
if [ -z "${MASTER_KEY:-}" ] && [ -f "${APP_DIR}/.env" ]; then
    MASTER_KEY=$(grep '^MASTER_KEY=' "${APP_DIR}/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
fi
MASTER_KEY="${MASTER_KEY:-admin-secreto-123}"
show_cmd "curl -s -X POST http://localhost:8001/admin/keys -H 'Content-Type: application/json' -H 'Authorization: Bearer ****' -d '{\"name\": \"test-ci-key\"}'"
AUTH_RESP=$(curl -s -X POST http://localhost:8001/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -d '{"name": "test-ci-key"}' || echo "{}")

API_KEY=$(echo "$AUTH_RESP" | grep -o '"key":"[^"]*' | cut -d'"' -f4)

if [ -n "$API_KEY" ]; then
    echo -e "${GREEN}✅ Chave de API gerada com sucesso: ${API_KEY:0:15}...${NC}"
else
    echo -e "${RED}❌ Falha ao obter chave de API do auth-service.${NC}"
    ERRORS=$((ERRORS + 1))
fi

# 2. Criar Flag
if [ -n "$API_KEY" ]; then
    show_cmd "curl -s -X POST http://localhost:8002/flags -H 'Authorization: Bearer ${API_KEY:0:8}****' -d '{\"name\": \"test-flag-ci\", \"is_enabled\": true}'"
    FLAG_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8002/flags \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $API_KEY" \
      -d '{"name": "test-flag-ci", "is_enabled": true}')
    if [ "$FLAG_RESP" == "201" ] || [ "$FLAG_RESP" == "200" ] || [ "$FLAG_RESP" == "409" ]; then
        echo -e "${GREEN}✅ Flag criada/validada no flag-service (HTTP $FLAG_RESP).${NC}"
    else
        echo -e "${RED}❌ Falha ao criar flag no flag-service (HTTP $FLAG_RESP).${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    # 3. Criar Regra de Targeting
    show_cmd "curl -s -X POST http://localhost:8003/rules -H 'Authorization: Bearer ${API_KEY:0:8}****' -d '{\"flag_name\": \"test-flag-ci\", \"is_enabled\": true, \"rules\": {\"type\": \"PERCENTAGE\", \"value\": 50}}'"
    RULE_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8003/rules \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $API_KEY" \
      -d '{"flag_name": "test-flag-ci", "is_enabled": true, "rules": {"type": "PERCENTAGE", "value": 50}}')
    if [ "$RULE_RESP" == "201" ] || [ "$RULE_RESP" == "200" ] || [ "$RULE_RESP" == "409" ]; then
        echo -e "${GREEN}✅ Regra de targeting criada/validada no targeting-service (HTTP $RULE_RESP).${NC}"
    else
        echo -e "${RED}❌ Falha no targeting-service (HTTP $RULE_RESP).${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    # 4. Avaliar Flag
    show_cmd "curl -s 'http://localhost:8004/evaluate?user_id=ci-user-1&flag_name=test-flag-ci'"
    EVAL_RESP=$(curl -s "http://localhost:8004/evaluate?user_id=ci-user-1&flag_name=test-flag-ci")
    if echo "$EVAL_RESP" | grep -q "result"; then
        echo -e "${GREEN}✅ Avaliação executada com sucesso no evaluation-service: $EVAL_RESP${NC}"
    else
        echo -e "${RED}❌ Falha ao executar avaliação no evaluation-service: $EVAL_RESP${NC}"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo -e "\n[Passo 4/4] Resumo da Validação"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}🎉 ETAPA 1 APROVADA: Todos os requisitos locais foram satisfeitos com 100% de sucesso!${NC}"
    exit 0
else
    echo -e "${RED}⚠️ ETAPA 1 COM PENDÊNCIAS: Foram detectados $ERRORS erro(s). Corrija antes de avançar.${NC}"
    exit 1
fi
