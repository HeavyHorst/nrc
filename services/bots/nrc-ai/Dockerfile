# Build stage
FROM golang:1.27-bookworm AS builder

WORKDIR /app

COPY protocol-go /protocol-go

COPY services/bots/nrc-ai/go.mod services/bots/nrc-ai/go.sum ./
RUN go mod download

COPY services/bots/nrc-ai/ .

RUN CGO_ENABLED=0 go build -o nrc-ai .

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --no-create-home nrcai

COPY --from=builder /app/nrc-ai /app/nrc-ai

WORKDIR /app
USER nrcai
EXPOSE 8091

CMD ["./nrc-ai"]
