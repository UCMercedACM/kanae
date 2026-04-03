FROM ghcr.io/astral-sh/uv:python3.14-trixie-slim AS build

# Compile bytecode and enable caching
# Ref: https://docs.astral.sh/uv/guides/integration/docker/#compiling-bytecode
# Ref: https://docs.astral.sh/uv/guides/integration/docker/#caching
ENV UV_COMPILE_BYTECODE=1 
ENV UV_LINK_MODE=copy

# Disable Python downloads as the system Python interpreter instead
ENV UV_PYTHON_DOWNLOADS=0

# Do not install development dependencies
ENV UV_NO_DEV=1

# Server is used here to explicitly denote what this application is
# "App" is too vague of a wording, and oftentimes leads to incorrect paths  
WORKDIR /app/

COPY pyproject.toml uv.lock gunicorn.conf.py /app/

# Install dependencies through lockfile
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project

# Add project source code
COPY ./server /app

# Install the rest (this allows for optimal caching)
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen

FROM python:3.14-slim-trixie

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/kanae
ENV HOME=/tmp

# Set up non-root user
RUN groupadd --system --gid 999 kanae \
 && useradd --system --gid 999 --uid 999 --no-create-home kanae

# Copy the server from the builder
COPY --from=build /app /kanae
COPY --chmod=005 deploy/launcher.sh /kanae/launcher.sh

WORKDIR /kanae/

# Place executables in the environment at the front of the path
ENV PATH="/kanae/.venv/bin:$PATH"

# Use non-root user
USER kanae

EXPOSE 8000

CMD ["/kanae/launcher.sh", "--bind", "0.0.0.0:8000"]

LABEL org.opencontainers.image.title="Kanae"
LABEL org.opencontainers.image.description="Internal backend server for ACM @ UC Merced"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/UCMercedACM/kanae"