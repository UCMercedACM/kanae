import os
from pathlib import Path

from gunicorn.arbiter import Arbiter
from gunicorn.workers.base import Worker
from prometheus_client import multiprocess


# Importing from core.py results in circular imports
def _is_docker() -> bool:
    path = Path("/proc/self/cgroup")
    dockerenv_path = Path("/.dockerenv")
    return dockerenv_path.exists() or (
        path.is_file() and any("docker" in line for line in path.open())
    )

def worker_exit(server: Arbiter, worker: Worker) -> None:
    multiprocess.mark_process_dead(pid=worker.pid)

bind = ["127.0.0.1:8000"]
workers = os.cpu_count() or 1
worker_class = "utils.workers.KanaeWorker"
wsgi_app = "launcher:app"
pythonpath = "server" if not _is_docker() else "."
