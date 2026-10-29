#!/bin/sh
set -e

echo "==> [Floci] Inicializando componentes AWS locais (SQS e DynamoDB)..."

# 1. Criar fila SQS ToggleMaster-EvaluationEvents
aws sqs create-queue \
  --queue-name ToggleMaster-EvaluationEvents \
  --region us-east-1 \
  --endpoint-url http://localhost:4566 || true

# 2. Criar tabela DynamoDB ToggleMasterAnalytics
aws dynamodb create-table \
  --table-name ToggleMasterAnalytics \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1 \
  --endpoint-url http://localhost:4566 || true

echo "==> [Floci] Recursos SQS e DynamoDB inicializados com sucesso!"
