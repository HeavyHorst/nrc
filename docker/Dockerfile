# Build stage for Odin WebSocket server
FROM ubuntu:24.04@sha256:77eb101c607d6e3d4f5ad0c8a02c2136c689b98aba1f359e6502ba517e5c57ec AS base
FROM base AS builder

# Install dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    clang \
    llvm \
    git \
    curl \
    ca-certificates \
    openssl \
    libopus-dev \
    libzstd-dev \
    && rm -rf /var/lib/apt/lists/*

# Build the same checksum-pinned SQLite library for linking and runtime.
WORKDIR /opt/sqlite-src
RUN curl --fail --location https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz -o sqlite.tar.gz \
    && echo 'b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4 *sqlite.tar.gz' > sqlite.sha3 \
    && openssl dgst -sha3-256 -r sqlite.tar.gz | diff - sqlite.sha3 \
    && tar -xzf sqlite.tar.gz --strip-components=1 \
    && ./configure --prefix=/opt/sqlite --disable-static --disable-readline --disable-static-shell \
    && make -j2 \
    && make install
RUN echo /opt/sqlite/lib > /etc/ld.so.conf.d/nrc-sqlite.conf && ldconfig

# Install the compiler used for the migration rehearsal, not upstream HEAD.
WORKDIR /opt
RUN git init Odin \
    && git -C Odin remote add origin https://github.com/odin-lang/Odin.git \
    && git -C Odin fetch --depth=1 origin 7e313bd6f1fa9ae887c7b522611481cbf2da4cac \
    && git -C Odin checkout --detach FETCH_HEAD
WORKDIR /opt/Odin
RUN make release

# Add Odin to PATH
ENV PATH="/opt/Odin:${PATH}"

# Copy source code
WORKDIR /app
COPY . .

# Build the server
RUN odin build . -out:server -o:speed -extra-linker-flags:-L/opt/sqlite/lib

# Runtime stage
FROM base AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    tzdata \
    libopus0 \
    libzstd1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/sqlite /opt/sqlite
RUN echo /opt/sqlite/lib > /etc/ld.so.conf.d/nrc-sqlite.conf && ldconfig

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
