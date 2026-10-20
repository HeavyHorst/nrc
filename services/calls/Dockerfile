# Build from repository root: docker build -f services/calls/Dockerfile .
FROM golang:1.26.8-alpine AS build
WORKDIR /src
COPY protocol-go/ protocol-go/
COPY services/calls/ services/calls/
WORKDIR /src/services/calls
RUN go mod download && CGO_ENABLED=0 go build -trimpath -o /calls ./cmd/nrc-calls
FROM alpine:3.23
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 calls && mkdir /data && chown calls:calls /data
USER calls
COPY --from=build /calls /usr/local/bin/calls
EXPOSE 8090
ENTRYPOINT ["calls"]
