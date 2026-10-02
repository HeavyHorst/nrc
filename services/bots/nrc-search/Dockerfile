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

# Download ONNX model, tokenizer, and ONNX Runtime
RUN mkdir -p /app/models && \
    curl -L -o /app/models/model.onnx \
    https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main/onnx/model.onnx && \
    curl -L -o /app/models/model.onnx_data \
    https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main/onnx/model.onnx_data && \
    curl -L -o /app/models/tokenizer.json \
    https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main/tokenizer.json && \
    curl -L -o /tmp/onnxruntime.tar.gz \
    https://github.com/microsoft/onnxruntime/releases/download/v1.24.1/onnxruntime-linux-x64-1.24.1.tgz && \
    tar -xzf /tmp/onnxruntime.tar.gz -C /usr/local && \
    ln -s /usr/local/onnxruntime-linux-x64-1.24.1/lib/libonnxruntime.so.1.24.1 /usr/local/lib/libonnxruntime.so && \
    ldconfig && \
    rm /tmp/onnxruntime.tar.gz

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libstdc++6 \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --no-create-home nrcsearch

COPY --from=builder /app/nrc-search /app/nrc-search
COPY --from=builder /app/models /app/models
COPY --from=builder /usr/local/onnxruntime-linux-x64-1.24.1/lib /usr/local/lib/onnxruntime

RUN mkdir -p /app/data && chown -R nrcsearch:nrcsearch /app/data /app/models && \
    ln -s /usr/local/lib/onnxruntime/libonnxruntime.so.1.24.1 /usr/local/lib/onnxruntime.so && \
    ln -s /usr/local/lib/onnxruntime/libonnxruntime.so.1.24.1 /usr/local/lib/libonnxruntime.so && \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/nrc.conf && \
    ldconfig

WORKDIR /app
USER nrcsearch
EXPOSE 8090

CMD ["./nrc-search"]
