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
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1
WORKDIR /srv
COPY pyproject.toml uv.lock ./
# uv is mounted from the pinned image for this step only; it is not in the final image.
RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv \
    uv export --frozen --no-dev --no-emit-project -o /tmp/req.txt \
 && pip install -r /tmp/req.txt && rm /tmp/req.txt
COPY app ./app
RUN useradd --uid 10001 --no-create-home app
USER 10001
CMD ["python", "-m", "app.main"]
