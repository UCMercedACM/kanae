import argparse
import os
import sys
from pathlib import Path

import uvicorn
from core import Kanae
from fastapi_pagination import add_pagination
from routes import router
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from starlette.middleware.cors import CORSMiddleware
from supertokens_python import get_all_cors_headers
from supertokens_python.framework.fastapi import get_middleware
from utils.config import KanaeConfig, KanaeUvicornConfig
from uvicorn.supervisors import Multiprocess

config_path = Path(__file__).parent / "config.yml"
config = KanaeConfig(config_path)

app = Kanae(config=config)
app.add_middleware(get_middleware())
app.include_router(router)
app.add_middleware(
    CORSMiddleware,
    allow_origins=config["auth"]["allowed_origins"],
    allow_credentials=True,
    allow_methods=["GET", "PUT", "POST", "DELETE", "OPTIONS", "PATCH"],
    allow_headers=["Content-Type"] + get_all_cors_headers(),
)
add_pagination(app)
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)  # type: ignore
app.state.limiter = router.limiter


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-H",
        "--host",
        default=config["kanae"]["host"],
        help="The host to bind to. Defaults to value set in config",
    )
    parser.add_argument(
        "-p",
        "--port",
        default=config["kanae"]["port"],
        help="The port to bind to. Defaults to value set in config",
        type=int,
    )
    parser.add_argument(
        "-nw",
        "--no-workers",
        action="store_true",
        default=False,
        help="Runs no workers",
    )
    parser.add_argument("-w", "--workers", default=os.cpu_count() or 1, type=int)

    args = parser.parse_args(sys.argv[1:])
    use_workers = not args.no_workers
    worker_count = args.workers

    config = KanaeUvicornConfig(
        "launcher:app", port=args.port, host=args.host, access_log=True
    )

    server = uvicorn.Server(config)

    if use_workers:
        config.workers = worker_count
        sock = config.bind_socket()

        runner = Multiprocess(config, target=server.run, sockets=[sock])
    else:
        runner = server

    runner.run()
