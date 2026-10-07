FROM node:24-bookworm-slim AS media-builder
WORKDIR /app
COPY services/bots/nrc-search/package.json services/bots/nrc-search/package-lock.json ./
RUN npm ci --omit=dev

# Build stage
FROM golang:1.26-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install HuggingFace tokenizers static library (for github.com/daulet/tokenizers)
RUN curl -L -o /tmp/libtokenizers.tar.gz \
    https://github.com/daulet/tokenizers/releases/download/v1.25.0/libtokenizers.linux-amd64.tar.gz && \
    tar -xzf /tmp/libtokenizers.tar.gz -C /usr/local/lib && \
    rm /tmp/libtokenizers.tar.gz

WORKDIR /app

COPY protocol-go /protocol-go

COPY services/bots/nrc-search/go.mod services/bots/nrc-search/go.sum ./
RUN go mod download

COPY services/bots/nrc-search/ .

RUN CGO_ENABLED=1 CGO_LDFLAGS="-L/usr/local/lib" go build -o nrc-search .

# Keep weights and tokenizer on the same tested revision.
ARG EMBEDDING_MODEL_REVISION=daa72c51243991dfcaf9f9137d2c573d8f7790c0
# Download ONNX model, tokenizer, and ONNX Runtime
RUN mkdir -p /app/models && \
    curl -fL --retry 3 -o /app/models/model.onnx \
    https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/resolve/${EMBEDDING_MODEL_REVISION}/onnx/model.onnx && \
    curl -fL --retry 3 -o /app/models/model.onnx_data \
    https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/resolve/${EMBEDDING_MODEL_REVISION}/onnx/model.onnx_data && \
    curl -fL --retry 3 -o /app/models/tokenizer.json \
    https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/resolve/${EMBEDDING_MODEL_REVISION}/tokenizer.json && \
    curl -L -o /tmp/onnxruntime.tar.gz \
    https://github.com/microsoft/onnxruntime/releases/download/v1.24.1/onnxruntime-linux-x64-1.24.1.tgz && \
    tar -xzf /tmp/onnxruntime.tar.gz -C /usr/local && \
    ln -s /usr/local/onnxruntime-linux-x64-1.24.1/lib/libonnxruntime.so.1.24.1 /usr/local/lib/libonnxruntime.so && \
    ldconfig && \
    rm /tmp/onnxruntime.tar.gz

# Only media encoders and processor configuration; no second text backbone.
RUN mkdir -p /app/models/onnx && \
    for file in config.json processor_config.json preprocessor_config.json tokenizer_config.json \
        onnx/vision_encoder.onnx onnx/vision_encoder.onnx_data \
        onnx/audio_encoder.onnx onnx/audio_encoder.onnx_data; do \
        curl -fL --retry 3 -o /app/models/$file \
        https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/resolve/${EMBEDDING_MODEL_REVISION}/$file || exit 1; \
    done

# Retain the previous model for serving existing 300M indexes during migration.
ARG LEGACY_MODEL_REVISION=5090578d9565bb06545b4552f76e6bc2c93e4a66
RUN mkdir -p /app/models/legacy && \
    for file in model.onnx model.onnx_data; do \
        curl -fL --retry 3 -o /app/models/legacy/$file \
        https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/${LEGACY_MODEL_REVISION}/onnx/$file || exit 1; \
    done && \
    curl -fL --retry 3 -o /app/models/legacy/tokenizer.json \
    https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/${LEGACY_MODEL_REVISION}/tokenizer.json

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libstdc++6 \
    libgomp1 \
    ffmpeg \
    poppler-utils \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --no-create-home nrcsearch

COPY --from=builder /app/nrc-search /app/nrc-search
COPY --from=builder /app/models /app/models
COPY --from=builder /app/media_worker.mjs /app/media_worker.mjs
COPY --from=media-builder /usr/local/bin/node /usr/local/bin/node
COPY --from=media-builder /app/node_modules /app/node_modules
COPY --from=builder /usr/local/onnxruntime-linux-x64-1.24.1/lib /usr/local/lib/onnxruntime

RUN mkdir -p /app/data && chown -R nrcsearch:nrcsearch /app/data /app/models && \
    ln -s /usr/local/lib/onnxruntime/libonnxruntime.so.1.24.1 /usr/local/lib/onnxruntime.so && \
    ln -s /usr/local/lib/onnxruntime/libonnxruntime.so.1.24.1 /usr/local/lib/libonnxruntime.so && \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/nrc.conf && \
    ldconfig

WORKDIR /app
ENV MEDIA_MODEL_DIR=/app/models MEDIA_WORKER_PATH=/app/media_worker.mjs
USER nrcsearch
EXPOSE 8090

CMD ["./nrc-search"]
