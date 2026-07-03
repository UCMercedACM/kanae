from __future__ import annotations

import argparse
from pathlib import Path
from typing import TYPE_CHECKING

import orjson

from main import app

if TYPE_CHECKING:
    from argparse import Namespace

ROOT_PATH = Path(__file__).parents[1]


def main(args: Namespace) -> None:
    path: Path = args.output

    if not path.parent.exists():
        path.parent.mkdir()

    path.write_bytes(orjson.dumps(app.openapi(), option=orjson.OPT_INDENT_2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path, default=Path("openapi.json"))

    main(parser.parse_args())
