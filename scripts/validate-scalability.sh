#!/usr/bin/env bash
set -e

NAMESPACE="${1:-togglemaster}"

echo "======================================================="
echo "⚡ Validador de Escalabilidade e Resiliência (HPA/KEDA)"
echo "Namespace: $NAMESPACE"
echo "======================================================="

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
show_cmd() { echo -e "\033[0;36m\$ $*\033[0m"; }

echo -e "\n[1/4] Verificando Metrics Server no cluster..."
show_cmd "kubectl top nodes"
if kubectl top nodes >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Metrics Server operacional (métricas disponíveis).${NC}"
else
    echo -e "${RED}❌ Metrics Server NÃO está respondendo. O HPA não funcionará sem ele!${NC}"
    echo "Execute: kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
fi

echo -e "\n[2/4] Verificando HPAs configurados..."
HPAS=$(kubectl get hpa -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$HPAS" -ge 1 ]; then
    echo -e "${GREEN}✅ Encontrado(s) $HPAS HPA(s) no namespace '$NAMESPACE'.${NC}"
    show_cmd "kubectl get hpa -n $NAMESPACE"
    kubectl get hpa -n "$NAMESPACE"
    show_cmd "kubectl get scaledobject -n $NAMESPACE"
    kubectl get scaledobject -n "$NAMESPACE" 2>/dev/null || true
else
    echo -e "${YELLOW}⚠️ Nenhum HPA encontrado no namespace '$NAMESPACE'.${NC}"
fi

echo -e "\n[3/4] Verificando status da tabela DynamoDB via AWS CLI..."
if command -v aws >/dev/null 2>&1; then
    show_cmd "aws dynamodb describe-table --table-name ToggleMasterAnalytics --query Table.TableStatus --output text"
    TABLE_STATUS=$(aws dynamodb describe-table --table-name ToggleMasterAnalytics --query "Table.TableStatus" --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$TABLE_STATUS" == "ACTIVE" ]; then
        show_cmd "aws dynamodb scan --table-name ToggleMasterAnalytics --select COUNT --query Count --output text"
        COUNT=$(aws dynamodb scan --table-name ToggleMasterAnalytics --select "COUNT" --query "Count" --output text 2>/dev/null || echo "0")
        echo -e "${GREEN}✅ Tabela DynamoDB 'ToggleMasterAnalytics' ATIVA ($COUNT itens gravados).${NC}"
    else
        echo -e "${YELLOW}⚠️ Tabela DynamoDB 'ToggleMasterAnalytics' não encontrada ou sem permissão na AWS CLI.${NC}"
    fi
else
    echo -e "${YELLOW}⚠️ AWS CLI não encontrada no PATH local.${NC}"
fi

echo -e "\n[4/4] Guia de Execução do Teste de Carga para o Vídeo:"
LB_HOST=$(kubectl get ingress togglemaster-ingress -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -z "$LB_HOST" ]; then
    LB_HOST=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
fi
if [ -z "$LB_HOST" ]; then
    LB_HOST=$(kubectl get ingress togglemaster-ingress -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

if [ -n "$LB_HOST" ]; then
    TARGET_URL="http://${LB_HOST}/evaluate?user_id=load-test&flag_name=dark-mode"
    echo -e "${GREEN}✅ Load Balancer detectado: http://${LB_HOST}${NC}"
    echo "Para estressar e demonstrar o HPA escalando ao vivo no vídeo, execute:"
    show_cmd "ab -r -k -t 25 -c 30 '${TARGET_URL}'"
    echo "ou utilize o script automatizado completo (HTTP + SQS + DynamoDB):"
    show_cmd "./scripts/load-test.sh"
else
    echo -e "${YELLOW}⚠️ Load Balancer não encontrado automaticamente no namespace '${NAMESPACE}'.${NC}"
    echo "Execute substituindo pelo endereço do seu LB:"
    show_cmd "ab -r -k -t 25 -c 30 'http://<LOADBALANCER_DNS>/evaluate?user_id=load-test&flag_name=dark-mode'"
fi
