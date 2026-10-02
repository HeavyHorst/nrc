# Build stage
FROM golang:1.26-bookworm AS builder

WORKDIR /app

COPY protocol-go /protocol-go

COPY services/bots/nrc-metrics/go.mod services/bots/nrc-metrics/go.sum ./
RUN go mod download

COPY services/bots/nrc-metrics/ ./

RUN CGO_ENABLED=0 go build -o nrc-metrics .

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --no-create-home nrcmetrics

COPY --from=builder /app/nrc-metrics /app/nrc-metrics

WORKDIR /app
USER nrcmetrics
EXPOSE 8092

CMD ["./nrc-metrics"]
