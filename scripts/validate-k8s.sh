#!/usr/bin/env bash
set -e

NAMESPACE="${1:-togglemaster}"

echo "======================================================="
echo "☸️ Validador Automático de Manifestos e Deploy K8s"
echo "Namespace Alvo: $NAMESPACE"
echo "======================================================="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
show_cmd() { echo -e "\033[0;36m\$ $*\033[0m"; }

echo -e "\n[Passo 1/5] Verificando existência do Namespace '$NAMESPACE'..."
show_cmd "kubectl get ns $NAMESPACE"
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Namespace '$NAMESPACE' existe.${NC}"
else
    echo -e "${RED}❌ Namespace '$NAMESPACE' não foi encontrado!${NC}"
    exit 1
fi

echo -e "\n[Passo 2/5] Auditando os 5 Deployments (Requests, Limits e Probes na Porta 80)..."
DEPLOYMENTS=("auth-service" "flag-service" "targeting-service" "evaluation-service" "analytics-service")

show_cmd "kubectl get deployment <svc> -n $NAMESPACE -o jsonpath='{...resources / livenessProbe / readinessProbe}'  # para os 5 serviços"
for DEP in "${DEPLOYMENTS[@]}"; do
    if ! kubectl get deployment "$DEP" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo -e "${RED}❌ Deployment '$DEP' não encontrado!${NC}"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Valida Requests e Limits
    CPU_REQ=$(kubectl get deployment "$DEP" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
    MEM_REQ=$(kubectl get deployment "$DEP" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null)
    CPU_LIM=$(kubectl get deployment "$DEP" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)
    MEM_LIM=$(kubectl get deployment "$DEP" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)

    if [ -n "$CPU_REQ" ] && [ -n "$MEM_REQ" ] && [ -n "$CPU_LIM" ] && [ -n "$MEM_LIM" ]; then
        echo -e "${GREEN}✅ $DEP: Requests e Limits configurados ($CPU_REQ / $MEM_REQ -> $CPU_LIM / $MEM_LIM).${NC}"
    else
        echo -e "${RED}❌ $DEP: Faltam Requests ou Limits obrigatórios pela banca!${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    # Valida Probes
    LIVENESS=$(kubectl get deployment "$DEP" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
    READINESS=$(kubectl get deployment "$DEP" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)

    if [ "$LIVENESS" == "/health" ] && [ "$READINESS" == "/health" ]; then
        echo -e "${GREEN}✅ $DEP: Liveness e Readiness Probes configurados em /health.${NC}"
    else
        echo -e "${YELLOW}⚠️ $DEP: Probes ausentes ou em caminho diferente de /health.${NC}"
        ERRORS=$((ERRORS + 1))
    fi
done

echo -e "\n[Passo 3/5] Verificando Services (ClusterIP escutando na porta 80)..."
show_cmd "kubectl get svc <svc> -n $NAMESPACE -o jsonpath='{.spec.ports[0].port}'  # para os 5 serviços"
for SVC in "${DEPLOYMENTS[@]}"; do
    PORT=$(kubectl get svc "$SVC" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "")
    if [ "$PORT" == "80" ]; then
        echo -e "${GREEN}✅ Service '$SVC': ClusterIP escutando na porta 80.${NC}"
    else
        echo -e "${RED}❌ Service '$SVC': Porta $PORT diferente da padronizada 80.${NC}"
        ERRORS=$((ERRORS + 1))
    fi
done

echo -e "\n[Passo 4/5] Verificando Roteamento Externo (Traefik Gateway API HTTPRoute + Ingress)..."
show_cmd "kubectl get httproute togglemaster-httproute -n $NAMESPACE"
if kubectl get httproute togglemaster-httproute -n "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Gateway API HTTPRoute 'togglemaster-httproute' configurado e ativo.${NC}"
fi
show_cmd "kubectl get ingress -n $NAMESPACE"
kubectl get ingress -n "$NAMESPACE" 2>/dev/null || true
INGRESS_HOST=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -z "$INGRESS_HOST" ]; then
    INGRESS_HOST=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
fi
if [ -n "$INGRESS_HOST" ]; then
    echo -e "${GREEN}✅ Traefik Gateway / Ingress operacional com Load Balancer provisionado: $INGRESS_HOST${NC}"
else
    echo -e "${YELLOW}⚠️ Traefik Gateway / Ingress encontrado mas hostname ainda pendente ou sem Load Balancer externo.${NC}"
fi

echo -e "\n[Passo 5/5] Resumo da Validação K8s"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}🎉 ETAPAS 3 e 4 APROVADAS: Cluster e manifestos em total conformidade com o edital FIAP!${NC}"
    exit 0
else
    echo -e "${RED}⚠️ ETAPA KUBERNETES COM $ERRORS PENDÊNCIAS. Ajuste os manifestos antes da gravação do vídeo.${NC}"
    exit 1
fi
