# Estágio 1: Builder das dependências Python
FROM python:3.11.17-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Estágio 2: Imagem final de runtime enxuta e segura
FROM python:3.11.17-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 10001 appuser \
    && useradd -u 10001 -g 10001 --create-home --shell /bin/bash appuser

# Copia pacotes instalados do builder para o PATH padrão
COPY --from=builder /install /usr/local
COPY . .

RUN chown -R 10001:10001 /app

# Padronização de portas internas conforme regras FIAP
ENV PYTHONUNBUFFERED=1 \
    PORT=80

EXPOSE 80

# Healthcheck em conformidade com Trivy DS-0026
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["curl", "-f", "http://localhost:80/health"]

USER 10001:10001

CMD ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "1", "app:app"]
