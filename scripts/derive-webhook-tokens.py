import logging
import sys
from pathlib import Path
from typing import Any

import yaml
from blake3 import blake3
from dotenv import set_key

ROOT_PATH = Path(__file__).parents[1]

CONFIG_PATH = ROOT_PATH / "config.yml"
DOCKER_ENV_PATH = ROOT_PATH / "docker" / ".env"

# MUST match with the constants in server/routes/members.py
# If regenerating hook keys, the version suffix must be bumped to change them
HOOKS: dict[str, bytes] = {
    "KRATOS_WEBHOOK_TOKEN_REGISTRATION": b"kratos.registration.v1",
    "KRATOS_WEBHOOK_TOKEN_SETTINGS": b"kratos.settings.v1"
}

_log = logging.getLogger(__name__)

def main() -> None:
    if not CONFIG_PATH.exists():
        msg = "Config could not be found"
        raise RuntimeError(msg)

    config: dict[str, Any] = yaml.safe_load(CONFIG_PATH.read_bytes())

    _hex = config["ory"]["kratos_webhook_master_key"]

    try:
        master_key = bytes.fromhex(_hex)
    except ValueError:
        sys.exit("error: ory.kratos_webhook_master_key must be hex-encoded")

    for name, context in HOOKS.items():
        digest = blake3(context, key=master_key).hexdigest()
        set_key(DOCKER_ENV_PATH, name, digest, quote_mode="never")

    print("Done")  # noqa: T201


if __name__ == "__main__":
    main()
