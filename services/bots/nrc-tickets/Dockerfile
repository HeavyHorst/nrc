FROM golang:1.26-bookworm AS builder
WORKDIR /src/services/bots/nrc-tickets
COPY protocol-go /src/protocol-go
COPY services/bots/nrc-tickets/go.mod services/bots/nrc-tickets/go.sum ./
RUN go mod download
COPY services/bots/nrc-tickets/ .
RUN CGO_ENABLED=0 go build -trimpath -o /nrc-tickets .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /nrc-tickets /app/nrc-tickets
WORKDIR /app
EXPOSE 8096
CMD ["/app/nrc-tickets"]
