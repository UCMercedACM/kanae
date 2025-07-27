import os

from prometheus_client import multiprocess

bind = ["127.0.0.1:8000", "unix:/run/kanae.sock"]
chdir = "server"
workers = os.cpu_count() or 1
worker_class = "utils.uvicorn.workers.KanaeWorker"

wsgi_app = "launcher:app"


def worker_exit(server, worker):
    multiprocess.mark_process_dead(pid=worker.pid)
