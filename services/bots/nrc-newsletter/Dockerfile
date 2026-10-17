FROM golang:1.26-bookworm AS builder
WORKDIR /src/services/bots/nrc-newsletter
COPY protocol-go /src/protocol-go
COPY services/bots/nrc-newsletter/go.mod services/bots/nrc-newsletter/go.sum ./
RUN go mod download
COPY services/bots/nrc-newsletter/ .
RUN CGO_ENABLED=0 go build -trimpath -o /nrc-newsletter .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* && mkdir -m 0700 /data
COPY --from=builder /nrc-newsletter /app/nrc-newsletter
WORKDIR /app
ENV NEWSLETTER_DATA_DIR=/data
EXPOSE 8096 8097
CMD ["/app/nrc-newsletter"]
