FROM rust:1.100-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
COPY rules/ rules/
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --locked && cp target/release/jidoka-code /usr/local/bin/jidoka-code

FROM python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends tini && rm -rf /var/lib/apt/lists/*
ARG SEMGREP_VERSION=1.146.0
RUN pip install --no-cache-dir "semgrep==${SEMGREP_VERSION}"
RUN useradd --create-home --uid 10001 jidoka && install -d -o jidoka -g jidoka /data
WORKDIR /app
COPY --from=builder /usr/local/bin/jidoka-code /usr/local/bin/jidoka-code
ENV JIDOKA_BIND=0.0.0.0 JIDOKA_DB=/data/reviews.sqlite3 SEMGREP_SEND_METRICS=off
USER jidoka
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/jidoka-code"]
