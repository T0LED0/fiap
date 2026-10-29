# Estágio 1: Build da aplicação Go (cross-compile nativo sem emulação QEMU)
FROM --platform=$BUILDPLATFORM golang:1.23.12-alpine AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /build

RUN apk add --no-cache git ca-certificates

# Cache de dependências
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true

# Copia código fonte e compila estaticamente
COPY . .
RUN go mod tidy && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /app/server .

# Estágio 2: Imagem final enxuta e segura (sem compilador em runtime)
FROM alpine:3.20.10

WORKDIR /app

# Criação de usuário não-root para segurança
RUN apk --no-cache add ca-certificates tzdata wget && \
    addgroup -g 10001 -S nonroot && \
    adduser -u 10001 -S nonroot -G nonroot

# Copia binário estático
COPY --from=builder /app/server /app/server

# Padronização de portas internas conforme regras FIAP
ENV PORT=80
EXPOSE 80

# Healthcheck em conformidade com Trivy DS-0026
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["wget", "-q", "--spider", "http://localhost:80/health"]

USER 10001:10001

ENTRYPOINT ["/app/server"]
