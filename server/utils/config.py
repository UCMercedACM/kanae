import logging
import os
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any, Generic, Optional, TypeVar, Union, overload

import yaml
from uvicorn.config import Config as UvicornConfig
from uvicorn.logging import TRACE_LOG_LEVEL

_T = TypeVar("_T")

LOG_LEVELS: dict[str, int] = {
    "critical": logging.CRITICAL,
    "error": logging.ERROR,
    "warning": logging.WARNING,
    "info": logging.INFO,
    "debug": logging.DEBUG,
    "trace": TRACE_LOG_LEVEL,
}


### Color Formatter for Logging


# Directly pulled from discord.py
# https://github.com/Rapptz/discord.py/blob/0e4f06103ee20d06fb6c0d64f75b1fc475905b95/discord/utils.py#L1306
class _ColourFormatter(logging.Formatter):
    # ANSI codes are a bit weird to decipher if you're unfamiliar with them, so here's a refresher
    # It starts off with a format like \x1b[XXXm where XXX is a semicolon separated list of commands
    # The important ones here relate to colour.
    # 30-37 are black, red, green, yellow, blue, magenta, cyan and white in that order
    # 40-47 are the same except for the background
    # 90-97 are the same but "bright" foreground
    # 100-107 are the same as the bright ones but for the background.
    # 1 means bold, 2 means dim, 0 means reset, and 4 means underline.

    LEVEL_COLOURS = [
        (logging.DEBUG, "\x1b[40;1m"),
        (logging.INFO, "\x1b[34;1m"),
        (logging.WARNING, "\x1b[33;1m"),
        (logging.ERROR, "\x1b[31m"),
        (logging.CRITICAL, "\x1b[41m"),
    ]

    FORMATS = {
        level: logging.Formatter(
            f"\x1b[30;1m%(asctime)s\x1b[0m {colour}%(levelname)-8s\x1b[0m \x1b[0m %(message)s",
            "%Y-%m-%d %H:%M:%S",
        )
        for level, colour in LEVEL_COLOURS
    }

    def format(self, record):
        formatter = self.FORMATS.get(record.levelno)
        if formatter is None:
            formatter = self.FORMATS[logging.DEBUG]

        # Override the traceback to always print in red
        if record.exc_info:
            text = formatter.formatException(record.exc_info)
            record.exc_text = f"\x1b[31m{text}\x1b[0m"

        output = formatter.format(record)

        # Remove the cache layer
        record.exc_text = None
        return output


### YAML based memory configuration


class KanaeConfig(Generic[_T]):
    def __init__(self, path: Path):
        self.path = path
        self._config: dict[str, Union[_T, Any]] = {}
        self.load_from_file()

    def load_from_file(self) -> None:
        try:
            with open(self.path, "r") as f:
                self._config: dict[str, Union[_T, Any]] = yaml.safe_load(f.read())
        except FileNotFoundError:
            self._config = {}

    @overload
    def get(self, key: Any) -> Optional[Union[_T, Any]]: ...

    @overload
    def get(self, key: Any, default: Any) -> Union[_T, Any]: ...

    def get(self, key: Any, default: Any = None) -> Optional[Union[_T, Any]]:
        """Retrieves a config entry."""
        return self._config.get(str(key), default)

    def replace(self, key: Any, value: Union[_T, Any]) -> None:
        """Replaces a config entry."""
        self._config[str(key)] = value

    def __contains__(self, item: Any) -> bool:
        return str(item) in self._config

    def __getitem__(self, item: Any) -> Union[_T, Any]:
        return self._config[str(item)]

    def __len__(self) -> int:
        return len(self._config)

    def all(self) -> dict[str, Union[_T, Any]]:
        return self._config


### Overridden and Custom Uvicorn Configuration


class KanaeUvicornConfig(UvicornConfig):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    ### Private utilities

    def _determine_level(self, level: Optional[Union[str, int]]) -> int:
        # Force return info level
        if not level:
            return logging.INFO

        if isinstance(level, str):
            return LOG_LEVELS[level]
        else:
            return level

    # Pulled from https://github.com/Rapptz/discord.py/blob/0e4f06103ee20d06fb6c0d64f75b1fc475905b95/discord/utils.py#L1285
    def _is_docker(self) -> bool:
        path = "/proc/self/cgroup"
        return os.path.exists("/.dockerenv") or (
            os.path.isfile(path) and any("docker" in line for line in open(path))
        )

    # Pulled from https://github.com/Rapptz/discord.py/blob/0e4f06103ee20d06fb6c0d64f75b1fc475905b95/discord/utils.py#L1290
    def _stream_supports_colour(self, stream: Any) -> bool:
        is_a_tty = hasattr(stream, "isatty") and stream.isatty()

        # Pycharm and Vscode support colour in their inbuilt editors
        if "PYCHARM_HOSTED" in os.environ or os.environ.get("TERM_PROGRAM") == "vscode":
            return is_a_tty

        if sys.platform != "win32":
            # Docker does not consistently have a tty attached to it
            return is_a_tty or self._is_docker()

        # ANSICON checks for things like ConEmu
        # WT_SESSION checks if this is Windows Terminal
        return is_a_tty and ("ANSICON" in os.environ or "WT_SESSION" in os.environ)

    def _determine_formatter(
        self, handler: Union[logging.StreamHandler, RotatingFileHandler]
    ) -> logging.Formatter:
        if isinstance(handler, logging.StreamHandler) and self._stream_supports_colour(
            handler.stream
        ):
            return _ColourFormatter()

        dt_fmt = "%Y-%m-%d %H:%M:%S"
        return logging.Formatter(
            "[{asctime}] [{levelname:<8}]{:^4}{message}", dt_fmt, style="{"
        )

    ### Logging override

    def configure_logging(self) -> None:
        max_bytes = 32 * 1024 * 1024  # 32 MiB
        logging.addLevelName(TRACE_LOG_LEVEL, "TRACE")

        # Apparently the main logs are redirected to this module...
        root = logging.getLogger("uvicorn.error")
        access_logger = logging.getLogger("uvicorn.access")
        asgi_logger = logging.getLogger("uvicorn.asgi")

        kanae_root = logging.getLogger("kanae")

        level = self._determine_level(self.log_level)

        handler = logging.StreamHandler()
        handler.setFormatter(self._determine_formatter(handler))

        if self.access_log:
            file_handler = RotatingFileHandler(
                filename="kanae-access.log",
                encoding="utf-8",
                mode="w",
                maxBytes=max_bytes,
                backupCount=5,
            )
            access_logger.setLevel(level)
            access_logger.addHandler(handler)

            if not self._is_docker():
                access_logger.addHandler(file_handler)

        root.setLevel(level)
        root.addHandler(handler)

        kanae_root.setLevel(level)
        kanae_root.addHandler(handler)

        asgi_logger.setLevel(level)
        asgi_logger.addHandler(handler)
