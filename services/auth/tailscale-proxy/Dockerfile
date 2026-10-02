FROM golang:1.27-alpine AS builder

WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true

COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -o tailscale-proxy .

FROM pandoc/typst:3.10.0.0-alpine

USER root
RUN apk add --no-cache ca-certificates

WORKDIR /app
COPY --from=builder /app/tailscale-proxy .

# Create directory for file storage
RUN addgroup -g 10001 exporter \
    && adduser -D -H -u 10001 -G exporter exporter \
    && mkdir -p /data/files \
    && chmod 755 /data/files

ENTRYPOINT ["/app/tailscale-proxy"]
