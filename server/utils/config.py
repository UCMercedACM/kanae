import sys
from pathlib import Path
from typing import Literal, Optional, TypeVar

import yaml
from pydantic import BaseModel

if sys.version_info >= (3, 12):
    from typing import Self, TypedDict
else:
    from typing_extensions import Self, TypedDict

_T = TypeVar("_T")


def find_config() -> Optional[Path]:
    config_path = Path("config.yml")
    alternative_path = config_path.parent.joinpath("server", "config.yml")

    if not config_path.exists() and not alternative_path.exists():
        return

    if not config_path.exists():
        return alternative_path.resolve()
    return config_path.resolve()


### Pydantic/TypedDict-based configuration


# Kanae related
class PrometheusConfig(TypedDict):
    enabled: bool
    host: str
    port: int


class InMemoryFallbackLimiterConfig(TypedDict):
    enabled: bool
    limits: list[str]


class LimiterConfig(TypedDict):
    enabled: bool
    headers_enabled: bool
    auto_check: bool
    swallow_errors: bool
    retry_after: Optional[Literal["http-date", "delta-seconds"]]
    default_limits: list[str]
    application_limits: list[str]
    in_memory_fallback: InMemoryFallbackLimiterConfig
    key_prefix: str
    key_style: Literal["endpoint", "url"]
    storage_uri: str


class InternalKanaeConfig(BaseModel, frozen=True):
    host: str
    port: int
    dev_mode: bool = False
    prometheus: PrometheusConfig
    limiter: LimiterConfig


# Supertokens/auth related


class GoogleAuthConfig(TypedDict):
    client_id: str
    client_secret: str
    scopes: list[str]


class AuthProviderConfig(TypedDict):
    google: GoogleAuthConfig


class AuthConfig(BaseModel, frozen=True):
    name: str
    api_domain: str
    website_domain: str
    allowed_origins: list[str]
    connection_uri: list[str]
    api_key: str
    providers: AuthProviderConfig


# Final Config


class KanaeConfig(BaseModel):
    kanae: InternalKanaeConfig
    auth: AuthConfig
    postgres_uri: str

    @classmethod
    def load_from_file(cls, path: Optional[Path]) -> Self:
        if not path:
            raise FileNotFoundError("Config file not found")

        with open(path, "r") as f:
            decoded = yaml.safe_load(f.read())
            return cls(**decoded)
