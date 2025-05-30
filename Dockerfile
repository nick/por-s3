# Build stage
FROM rust:alpine AS builder

# Install build dependencies
RUN apk add --no-cache git musl-dev build-base

# Set up nightly toolchain
RUN rustup toolchain install nightly
RUN rustup default nightly

# Clone and build the project
WORKDIR /build
RUN git clone https://github.com/otter-sec/por_v2.git .
RUN cargo build --release --bin plonky2_por

# Runtime stage
FROM alpine:3.20

# Install required packages including bash and zip
RUN apk add --no-cache ca-certificates aws-cli bash zip

# Copy the built binary
COPY --from=builder /build/target/release/plonky2_por /usr/local/bin/
RUN chmod +x /usr/local/bin/plonky2_por

# Copy the processing script
COPY process_proofs.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/process_proofs.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/process_proofs.sh"]