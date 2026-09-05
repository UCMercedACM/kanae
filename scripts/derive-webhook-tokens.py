import argparse
import logging
import sys
from pathlib import Path
from typing import Any, TypedDict

import yaml
from blake3 import blake3
from dotenv import set_key

KEY_SIZE = 32
ROOT_PATH = Path(__file__).resolve().parents[1]

CONFIG_PATH = ROOT_PATH / "config.yml"
DOCKER_ENV_PATH = ROOT_PATH / "docker" / ".env"
PROD_ENV_PATH = ROOT_PATH / "deploy" / "docker" / ".deploy.env"

# MUST match with the constants in src/routes/members.py
# If regenerating hook keys, the version suffix must be bumped to change them
HOOKS: dict[str, bytes] = {
    "KRATOS_WEBHOOK_TOKEN_REGISTRATION": b"kratos.registration.v1",
    "KRATOS_WEBHOOK_TOKEN_SETTINGS": b"kratos.settings.v1",
}


_log = logging.getLogger(__name__)


class TokensOutput(TypedDict):
    name: str


def derive_tokens(master_hex: bytes) -> TokensOutput:
    try:
        master_key = bytes.fromhex(master_hex)
    except (TypeError, ValueError):
        sys.exit("error: ory.kratos_webhook_master_key must be hex-encoded")

    if len(master_key) != KEY_SIZE:
        sys.exit(f"error: ory.kratos_webhook_master_key must be {KEY_SIZE} bytes")

    return TokensOutput(
        {
            name: blake3(context, key=master_key).hexdigest()
            for name, context in HOOKS.items()
        }
    )


def main(config_path: Path, *, stdin: bool) -> None:
    if stdin:
        _hex = sys.stdin.read()
        derived_tokens = derive_tokens(_hex)

        for name, digest in derived_tokens.items():
            print(f"{name}={digest}")  # noqa: T201

        return

    config_path = config_path.resolve()
    if not config_path.is_relative_to(ROOT_PATH):
        sys.exit(f"error: config must live inside {ROOT_PATH}: {config_path}")

    if not config_path.exists():
        msg = f"Config could not be found: {config_path}"
        raise RuntimeError(msg)

    config: dict[str, Any] = yaml.safe_load(config_path.read_bytes())

    _hex = config["ory"]["kratos_webhook_master_key"]

    tokens = derive_tokens(_hex)

    for name, digest in tokens.items():
        set_key(DOCKER_ENV_PATH, name, digest, quote_mode="never")

        if PROD_ENV_PATH.exists():
            set_key(PROD_ENV_PATH, name, digest, quote_mode="never")

    print("Done")  # noqa: T201


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        type=Path,
        default=CONFIG_PATH,
        help=f"Path of the config file. Defaults to {CONFIG_PATH}",
    )
    parser.add_argument(
        "--stdin",
        action="store_true",
        help="Read the hex master key from stdin and print the tokens to stdout",
    )
    args = parser.parse_args()

    main(args.config, stdin=args.stdin)
