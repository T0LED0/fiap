#!/usr/bin/env bash
set -e

echo "==> [DB Init] Criando bancos de dados flags_db e targeting_db no PostgreSQL..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE flags_db;
    CREATE DATABASE targeting_db;
EOSQL

echo "==> [DB Init] Aplicando schema e triggers em flags_db..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "flags_db" -f /docker-entrypoint-initdb.d/flags-schema.sql

echo "==> [DB Init] Aplicando schema e triggers em targeting_db..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "targeting_db" -f /docker-entrypoint-initdb.d/targeting-schema.sql

echo "==> [DB Init] Bancos flags_db e targeting_db inicializados com sucesso!"
