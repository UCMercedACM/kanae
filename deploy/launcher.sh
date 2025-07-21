#!/usr/bin/env sh

# We have to do this as when using gunicorn
# Prometheus client libraries do a weird hack to put the multiproc in a folder instead
# Thus, it is recommended to make and set the temp directory within an startup script
# See: https://prometheus.github.io/client_python/multiprocess/
PROMETHEUS_MULTIPROC_DIR=$(mktemp --directory) python3 -m gunicorn