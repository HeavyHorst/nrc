FROM golang:1.26-bookworm AS builder
WORKDIR /src/services/bots/nrc-publish
COPY protocol-go /src/protocol-go
COPY services/bots/nrc-publish/go.mod services/bots/nrc-publish/go.sum ./
RUN go mod download
COPY services/bots/nrc-publish/ .
RUN CGO_ENABLED=0 go build -trimpath -o /nrc-publish .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -m 0700 /data
COPY --from=builder /nrc-publish /app/nrc-publish
# NRC's private workspace-grant markers are owned by the root-run auth proxy.
# The Compose overlay drops all capabilities and mounts the source read-only.
WORKDIR /app
ENV PUBLISH_DATA_DIR=/data
EXPOSE 8093 8094
CMD ["/app/nrc-publish"]
