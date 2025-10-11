FROM ghcr.io/astral-sh/uv:python3.13-trixie-slim AS build

# Compile bytecode and enable caching
# Ref: https://docs.astral.sh/uv/guides/integration/docker/#compiling-bytecode
# Ref: https://docs.astral.sh/uv/guides/integration/docker/#caching
ENV UV_COMPILE_BYTECODE=1 
ENV UV_LINK_MODE=copy

# Disable Python downloads as the system Python interpreter instead
ENV UV_PYTHON_DOWNLOADS=0

# Set Tini version
# Ref: https://github.com/krallin/tini?tab=readme-ov-file#using-tini
ENV TINI_VERSION=v0.19.0

ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini

WORKDIR /kanae/

COPY requirements.txt /kanae

# Install dependencies
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=requirements.txt,target=requirements.txt \
    uv venv && uv pip install -r requirements.txt

# Add project source code
COPY server /kanae

FROM python:3.13-slim-trixie

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/kanae

# Set up non-root user
RUN groupadd --system --gid 999 kanae \
 && useradd --system --gid 999 --uid 999 --no-create-home kanae

# Copy the server from the builder
COPY --from=build /kanae /kanae
COPY --from=build --chmod=+x /tini /tini

WORKDIR /kanae/

# Place executables in the environment at the front of the path
ENV PATH="/kanae/.venv/bin:$PATH"

# Use non-root user
USER kanae

EXPOSE 8000

ENTRYPOINT ["/tini", "--"]

CMD ["python3", "/kanae/launcher.py"]

STOPSIGNAL SIGTERM

LABEL org.opencontainers.image.title="Kanae"
LABEL org.opencontainers.image.description="Internal backend server for ACM @ UC Merced"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/UCMercedACM/kanae"
