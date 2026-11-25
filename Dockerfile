FROM rust:1.100-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
COPY rules/ rules/
COPY runner/ runner/
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --locked && cp target/release/jidoka-code /usr/local/bin/jidoka-code

FROM debian:bookworm-slim AS agy-egress
RUN apt-get update && apt-get install -y --no-install-recommends squid && rm -rf /var/lib/apt/lists/*
COPY runner/squid.conf /etc/squid/jidoka.conf
USER proxy
CMD ["squid", "-N", "-f", "/etc/squid/jidoka.conf"]

FROM python:3.12-slim-bookworm AS agy-runner
RUN apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates tini ripgrep && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir 'google-auth[requests]>=2.38,<3' && install -d -m 0700 /authority
COPY runner/adc.py /usr/local/lib/jidoka/adc.py
ARG TARGETARCH
RUN set -eu; case "$TARGETARCH" in \
      arm64) artifact="linux-arm/cli_linux_arm64"; hash="23c193151499a4986fd5fa0d8132665cc8ffbad6cc0b3ff4fd53a2cb68abb76b149a992b836d53063443cd89add335f14d8134fb02abdcecbf6e1eaef6c53d33" ;; \
      amd64) artifact="linux-x64/cli_linux_x64"; hash="3dee9f26e298156db673f6ce2a0f5dfed5b30006e04ceb9809c68070e7b717587b33a3da0f8bc2eda45af81a50bc8b14c82b28ae5832bcfe3e7fd49397117b31" ;; \
      *) exit 1 ;; esac; \
    curl -fsSLo /tmp/agy.tar.gz "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.16-5250855658717184/$artifact.tar.gz"; \
    echo "$hash  /tmp/agy.tar.gz" | sha512sum -c -; \
    tar -xOzf /tmp/agy.tar.gz antigravity > /usr/local/bin/agy; chmod 0755 /usr/local/bin/agy; rm /tmp/agy.tar.gz
RUN useradd --uid 10002 --no-create-home agy && install -d -m 0711 -o 10001 -g 10001 /jobs && install -d -m 0700 -o 10001 -g 10001 /control
COPY --from=builder /usr/local/bin/jidoka-code /usr/local/bin/jidoka-code
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/jidoka-code", "--agy-runner"]

FROM python:3.12-slim-bookworm AS web
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates tini && rm -rf /var/lib/apt/lists/*
ARG SEMGREP_VERSION=1.146.0
RUN pip install --no-cache-dir "semgrep==${SEMGREP_VERSION}"
RUN useradd --create-home --uid 10001 jidoka && install -d -o jidoka -g jidoka /data && install -d -m 0711 -o jidoka -g jidoka /jobs && install -d -m 0700 -o jidoka -g jidoka /control
WORKDIR /app
COPY --from=builder /usr/local/bin/jidoka-code /usr/local/bin/jidoka-code
ENV JIDOKA_BIND=0.0.0.0 JIDOKA_DB=/data/reviews.sqlite3 SEMGREP_SEND_METRICS=off
USER jidoka
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/jidoka-code"]
