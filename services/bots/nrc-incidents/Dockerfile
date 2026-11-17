FROM golang:1.27.4-bookworm AS builder
WORKDIR /src/services/bots/nrc-incidents
COPY protocol-go /src/protocol-go
COPY services/bots/nrc-incidents/go.mod services/bots/nrc-incidents/go.sum ./
RUN go mod download
COPY services/bots/nrc-incidents/ .
RUN CGO_ENABLED=1 go build -mod=readonly -trimpath -o /nrc-incidents .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libstdc++6 libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 monitoring \
    && useradd --uid 10001 --gid monitoring --no-create-home monitoring \
    && install -d -m 0700 -o monitoring -g monitoring /data
COPY --from=builder /nrc-incidents /app/nrc-incidents
USER monitoring
WORKDIR /app
ENTRYPOINT ["/app/nrc-incidents"]
