FROM python:3.12-slim
ARG SEMGREP_VERSION=1.146.0
RUN pip install --no-cache-dir "semgrep==${SEMGREP_VERSION}" && semgrep --version
RUN useradd --create-home --uid 10001 jidoka && install -d -o jidoka -g jidoka /data
WORKDIR /app
COPY jidoka/ jidoka/
COPY rules/ rules/
ENV JIDOKA_BIND=0.0.0.0 JIDOKA_DB=/data/reviews.sqlite3 SEMGREP_SEND_METRICS=off PYTHONDONTWRITEBYTECODE=1
USER jidoka
CMD ["python", "-m", "jidoka.app"]
