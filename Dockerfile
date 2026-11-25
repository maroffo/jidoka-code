FROM rust:1.100-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
COPY rules/ rules/
COPY runner/ runner/
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --locked && cp target/release/jidoka-code /usr/local/bin/jidoka-code

FROM python:3.12-slim-bookworm AS agy-runner
RUN apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates tini ripgrep && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir 'google-auth[requests]>=2.38,<3' && install -d -m 0700 /authority
COPY runner/adc.py /usr/local/lib/jidoka/adc.py
RUN curl -fsSLo /tmp/agy-install.sh https://antigravity.google/cli/install.sh && bash /tmp/agy-install.sh --dir /usr/local/bin && rm /tmp/agy-install.sh
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
