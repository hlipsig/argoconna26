# PYTHON_IMAGE and UV_IMAGE come from versions.env (the Makefile passes them as
# build args). Neither has a default, so a build without them fails.
ARG PYTHON_IMAGE
ARG UV_IMAGE
FROM ${UV_IMAGE} AS uv
FROM ${PYTHON_IMAGE}
# Trust the same public CA bundle as the WSL host when a corporate proxy is present.
RUN --mount=type=secret,id=host_ca,required=false \
    if [ -s /run/secrets/host_ca ]; then cp /run/secrets/host_ca /etc/ssl/certs/ca-certificates.crt; fi
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 UV_LINK_MODE=copy
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock README* ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
COPY schemas ./schemas
COPY fixtures ./fixtures
RUN uv sync --frozen --no-dev
# /data is created and owned by the runtime user so the image also starts without
# a volume; the Deployment mounts its PVC there (Task 3.2).
RUN mkdir -p /data && chown 10001 /data
ENV CDEVENTS_STORE=/data/events.jsonl SEED_FIXTURE=/app/fixtures/seed-history.json PATH="/app/.venv/bin:$PATH"
USER 10001
EXPOSE 8080
CMD ["uvicorn", "cdevents_sim.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080"]
