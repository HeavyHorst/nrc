# Build stage for Odin WebSocket server
FROM ubuntu:24.04 as builder

# Install dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    clang \
    llvm \
    git \
    curl \
    libopus-dev \
    libzstd-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Odin
WORKDIR /opt
RUN git clone https://github.com/odin-lang/Odin.git
WORKDIR /opt/Odin
RUN make release

# Add Odin to PATH
ENV PATH="/opt/Odin:${PATH}"

# Copy source code
WORKDIR /app
COPY . .

# Build the server
RUN odin build . -out:server -o:speed

# Runtime stage
FROM ubuntu:24.04

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libopus0 \
    libzstd1 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r orion && useradd -r -g orion orion

# Copy the built binary
COPY --from=builder /app/server /usr/local/bin/server
RUN chmod +x /usr/local/bin/server

# Create data directory for task persistence (volume mount point)
RUN mkdir -p /app/data && chown orion:orion /app/data
WORKDIR /app

# Switch to non-root user
USER orion

# Expose WebSocket port
EXPOSE 8080

# Run the server
CMD ["server"]
