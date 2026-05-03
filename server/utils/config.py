from pathlib import Path
from typing import Literal, Optional, Self, TypedDict

import yaml
from pydantic import BaseModel


def find_config() -> Optional[Path]:
    config_path = Path("config.yml")
    alternative_path = config_path.parent.joinpath("server", "config.yml")

    if not config_path.exists() and not alternative_path.exists():
        return None

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
    allowed_origins: list[str]
    prometheus: PrometheusConfig
    limiter: LimiterConfig


class OryConfig(BaseModel, frozen=True):
    kratos_public_url: str
    kratos_admin_url: str
    keto_read_url: str
    keto_write_url: str
    kratos_webhook_master_key: str


# Final Config


class KanaeConfig(BaseModel):
    kanae: InternalKanaeConfig
    ory: OryConfig
    postgres_uri: str

    @classmethod
    def load_from_file(cls, path: Optional[Path]) -> Self:
        if not path:
            msg = "Config file not found"
            raise FileNotFoundError(msg)

        with path.open() as f:
            decoded = yaml.safe_load(f.read())
            return cls(**decoded)
