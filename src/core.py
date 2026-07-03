from __future__ import annotations

import asyncio
import datetime
import http
import itertools
import logging
import mimetypes
import re
import sys
import time
from contextlib import asynccontextmanager
from copy import copy
from logging import NullHandler
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import (
    TYPE_CHECKING,
    Any,
    ClassVar,
    Literal,
    NamedTuple,
    Optional,
    Self,
    TypedDict,
    cast,
)

import aiohttp
import asyncpg
import click
import orjson
import pyvips
import yaml
from aiobotocore.config import AioConfig
from aiobotocore.session import AioSession
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from blake3 import blake3
from botocore.config import Config as BotoConfig
from botocore.exceptions import ClientError as BotoClientError
from botocore.session import Session
from fastapi import Depends, FastAPI, status
from fastapi.exceptions import HTTPException, RequestValidationError
from fastapi.openapi.utils import get_openapi
from fastapi.requests import Request
from fastapi.responses import Response
from fastapi.utils import is_body_allowed_for_status_code
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    REGISTRY,
    CollectorRegistry,
    Gauge,
    generate_latest,
)
from prometheus_fastapi_instrumentator import metrics, routing
from pydantic import BaseModel
from starlette.datastructures import Headers

from utils.cache import ORJSONSerializer, ValkeyCache, cached_method
from utils.errors import BadRequestError, NotFoundError
from utils.glide import GlideManager
from utils.limiter.extension import (
    KanaeLimiter,
    RateLimitExceeded,
    rate_limit_exceeded_handler,
)
from utils.ory import OryClient, OryConfig
from utils.responses import (
    HTTPExceptionResponse,
    ORJSONResponse,
    RequestValidationErrorResponse,
)

if TYPE_CHECKING:
    from collections.abc import (
        AsyncGenerator,
        Awaitable,
        Callable,
        Generator,
        Iterator,
        Sequence,
    )

    from starlette.types import Message, Receive, Scope, Send
    from types_aiobotocore_s3 import S3Client
    from types_aiobotocore_s3.type_defs import HeadObjectOutputTypeDef
    from types_boto3_s3 import S3Client as BotoS3Client

    from utils.request import RouteRequest

__title__ = "Kanae"
__description__ = """
Kanae is ACM @ UC Merced's API.

This document details the API as it is right now.
Changes can be made without notification, but announcements will be made for major changes.
"""
__version__ = "0.2.0"

LATENCY_HIGHER_BUCKETS = (
    0.01,
    0.025,
    0.05,
    0.075,
    0.1,
    0.25,
    0.5,
    0.75,
    1,
    1.5,
    2,
    2.5,
    3,
    3.5,
    4,
    4.5,
    5,
    7.5,
    10,
    30,
    60,
)
LATENCY_LOWER_BUCKETS = (0.1, 0.5, 1)

MAX_BYTES = 32 * 1024 * 1024  # 32 MB
BACKUP_COUNT = 10

ALLOWED_IMAGE_TYPES = frozenset(
    {
        "image/jpeg",
        "image/png",
        "image/webp",
        "image/gif",
    }
)
ALLOWED_VIDEO_TYPES = frozenset(
    {
        "video/mp4",
        "video/webm",
        "video/quicktime",
    }
)

_PRESIGN_PUT_TTL = 900  # 15 min
_PRESIGN_GET_TTL = 300  # 5 min
_GET_URL_CACHE_TTL = max(_PRESIGN_GET_TTL - 30, 30)

_S3_MIN_CHUNK_SIZE = 5 * 1024 * 1024
_TARGET_CHUNK_COUNT = 128
_ONE_MIB = 1024 * 1024
_TARGET_BUCKET = _TARGET_CHUNK_COUNT * _ONE_MIB

_THUMBNAIL_MAX_W = 1600
_THUMBNAIL_MAX_H = 500
_WEBP_QUALITY = 75
_WEBP_EFFORT = 6


def _is_docker() -> bool:
    path = Path("/proc/self/cgroup")
    dockerenv_path = Path("/.dockerenv")
    return dockerenv_path.exists() or (
        path.is_file() and any("docker" in line for line in path.open())
    )


def find_config() -> Optional[Path]:
    base = Path("config.yml")
    targets = [base, base.parent.joinpath("src", "config.yml")]

    return next((path.resolve() for path in targets if path.exists()), None)


async def init(conn: asyncpg.Connection) -> None:
    # Refer to https://github.com/MagicStack/asyncpg/issues/140#issuecomment-301477123
    def _encode_jsonb(value: Any) -> bytes:  # noqa: ANN401
        return b"\x01" + orjson.dumps(value)

    def _decode_jsonb(value: bytes) -> Any:  # noqa: ANN401
        return orjson.loads(value[1:].decode("utf-8"))

    await conn.set_type_codec(
        "jsonb",
        schema="pg_catalog",
        encoder=_encode_jsonb,
        decoder=_decode_jsonb,
        format="binary",
    )


### App configuration


class InstrumentatorSettings(BaseModel, frozen=True):
    should_group_status_codes: bool = True
    should_ignore_not_templated: bool = False
    should_group_not_templated: bool = True
    should_round_latency_decimals: bool = False
    should_instrument_requests_in_progress: bool = False
    should_exclude_streaming_duration: bool = False
    in_progress_name: str = "http_requests_in_progress"
    in_progress_labels: bool = False
    metric_namespace: str = ""
    metric_subsystem: str = ""


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


class PublicConfig(TypedDict):
    bucket: str
    url: str


class StorageConfig(BaseModel, frozen=True):
    url: str
    presign_url: str
    region: str = "garage"
    bucket: str
    public: PublicConfig
    key_id: str
    secret_key: str


# Final client to use
class KanaeConfig(BaseModel):
    kanae: InternalKanaeConfig
    ory: OryConfig
    storage: StorageConfig
    postgres_uri: str

    @classmethod
    def load_from_file(cls, path: Optional[Path]) -> Self:
        if not path:
            msg = "Config file not found"
            raise FileNotFoundError(msg)

        with path.open() as f:
            decoded = yaml.safe_load(f.read())
            return cls(**decoded)


### Logging


def rotating_handler(
    filename: str = "logs/kanae.log",
) -> AppRotatingHandler | NullHandler:
    # Docker maintains a stateless philosophy, i.e., that there must be no state that must be written as a container should only be read-only
    # In simpler terms, you can't write a file within a docker container, and that is true with ours (as it would error out regardless)
    # Thus, we won't write logs if the code is running in a docker container, as represented with the NullHandler
    # We also can't send back an None as the logger explicitly requires an handler be returned
    if not _is_docker():
        return AppRotatingHandler(filename=filename)

    return NullHandler()


class AppRotatingHandler(RotatingFileHandler):
    def __init__(self, filename: str) -> None:
        resolved_filename = Path(filename)
        if not resolved_filename.parent.exists():
            resolved_filename.parent.mkdir(parents=True, exist_ok=True)

        super().__init__(
            filename=resolved_filename,
            encoding="utf-8",
            maxBytes=MAX_BYTES,
            backupCount=BACKUP_COUNT,
        )


class ColourizedFormatter(logging.Formatter):
    """
    A custom log formatter class that:

    * Outputs the LOG_LEVEL with an appropriate color.
    * If a log call includes an `extra={"color_message": ...}` it will be used
      for formatting the output, instead of the plain text message.
    """

    LEVEL_COLOURS: ClassVar[dict[int, str]] = {
        logging.DEBUG: "cyan",
        logging.INFO: "green",
        logging.WARNING: "yellow",
        logging.ERROR: "red",
        logging.CRITICAL: "bright_red",
    }

    _LEVEL_WIDTH: ClassVar[int] = 8

    def __init__(
        self,
        fmt: str | None = None,
        datefmt: str | None = None,
        style: Literal["%", "{", "$"] = "%",
        *,
        use_colors: bool | None = None,
    ) -> None:
        self.use_colors = (
            use_colors if use_colors is not None else self.should_use_colors()
        )
        self._level_prefix: dict[int, str] = {
            level_no: self._build_level_prefix(level_no)
            for level_no in self.LEVEL_COLOURS
        }
        super().__init__(fmt=fmt, datefmt=datefmt, style=style)

    def _build_level_prefix(self, level_no: int) -> str:
        name = logging.getLevelName(level_no)
        plain = f"{name}:".ljust(self._LEVEL_WIDTH + 1)
        colour = self.LEVEL_COLOURS.get(level_no) if self.use_colors else None
        if colour is None:
            return plain
        return click.style(name, fg=colour) + plain[len(name) :]

    def _level_prefix_for(self, record: logging.LogRecord) -> str:
        cached = self._level_prefix.get(record.levelno)
        if cached is None:
            cached = self._build_level_prefix(record.levelno)
            self._level_prefix[record.levelno] = cached
        return cached

    def should_use_colors(self) -> bool:
        return True

    def formatMessage(self, record: logging.LogRecord) -> str:
        record_copy = copy(record)
        if self.use_colors and "color_message" in record_copy.__dict__:
            record_copy.msg = record_copy.__dict__["color_message"]
            record_copy.__dict__["message"] = record_copy.getMessage()
        record_copy.__dict__["levelprefix"] = self._level_prefix_for(record_copy)
        return super().formatMessage(record_copy)


class DefaultFormatter(ColourizedFormatter):
    def should_use_colors(self) -> bool:
        return sys.stderr.isatty()


class AccessFormatter(ColourizedFormatter):
    STATUS_COLOURS: ClassVar[dict[int, str]] = {
        1: "bright_white",
        2: "green",
        3: "yellow",
        4: "red",
        5: "bright_red",
    }

    def should_use_colors(self) -> bool:
        return sys.stdout.isatty()

    def get_status_code(self, status_code: int) -> str:
        try:
            phrase = http.HTTPStatus(status_code).phrase
        except ValueError:
            phrase = ""

        rendered = f"{status_code} {phrase}"
        colour = (
            self.STATUS_COLOURS.get(status_code // 100) if self.use_colors else None
        )
        if colour is None:
            return rendered
        return click.style(rendered, fg=colour)

    def formatMessage(self, record: logging.LogRecord) -> str:
        # Granian's access logger passes args as a dict, e.g.
        #   {"addr", "time", "method", "path", "protocol", "status",
        #    "dt_ms", "query_string", "scheme"}
        # See: https://github.com/emmett-framework/granian#access-log-format
        record_copy = copy(record)
        args = cast("dict[str, Any]", record_copy.args)
        request_line = f"{args['method']} {args['path']} {args['protocol']}"
        if self.use_colors:
            request_line = click.style(request_line, bold=True)
        copied_dict = record_copy.__dict__
        copied_dict["levelprefix"] = self._level_prefix_for(record_copy)
        copied_dict["client_addr"] = args["addr"]
        copied_dict["request_line"] = request_line
        copied_dict["status_code"] = self.get_status_code(args["status"])
        return logging.Formatter.formatMessage(self, record_copy)


### S3 Storage client


# This lives here as this may be used across multiple routes.
# For now, the project routes uses this only, but may get moved to here later
def fetch_and_process_thumbnail(
    client: BotoS3Client, bucket: str, key: str
) -> ProcessedThumbnail:
    """Fetch a source image from S3 and produce a WebP thumbnail.

    This is done via pyvips instead of pillow to maxmize performance within a resource-constrained environment

    Args:
        client (BotoS3Client): Sync botocore S3 client used to GetObject the source.
        bucket (str): Bucket containing the source media.
        key (str): Object key of the source media.

    Returns:
        ProcessedThumbnail: Encoded WebP bytes plus the BLAKE3 hex digest of those bytes.
    """
    response = client.get_object(Bucket=bucket, Key=key)

    # We are going to stream the whole entire thing into pyvips
    with response["Body"] as body:
        source = pyvips.SourceCustom()
        source.on_read(body.read)

        # thumbnail_source is autogenerated, so it doesn't show up for ty
        # we will force it to be pyvips.Image as that is correct
        # see: https://github.com/libvips/pyvips/blob/master/examples/generate_type_stubs.py#L11-L18
        image: pyvips.Image = pyvips.Image.thumbnail_source(
            source,
            _THUMBNAIL_MAX_W,
            height=_THUMBNAIL_MAX_H,
            size=pyvips.Size.DOWN,
            crop=pyvips.Interesting.NONE,
            intent=pyvips.Intent.PERCEPTUAL,
        )
        output: bytes = image.write_to_buffer(
            ".webp",
            Q=_WEBP_QUALITY,
            effort=_WEBP_EFFORT,
            strip=True,
        )

    return ProcessedThumbnail(output, blake3(output).hexdigest())


async def store_thumbnail(
    request: RouteRequest, *, media_hash: str, content_type: str
) -> ProcessedThumbnail:
    if content_type not in ALLOWED_IMAGE_TYPES:
        msg = "Thumbnail must be an image"
        raise BadRequestError(msg)

    key = request.app.storage._build_key(media_hash, content_type)
    try:
        # ty thinks that sync_storage is incorrect, but it's correct
        processed_image = await asyncio.to_thread(
            fetch_and_process_thumbnail,
            request.app.sync_storage,
            request.app.storage.bucket,
            key,
        )
    except BotoClientError:
        msg = "No such media exists"
        raise NotFoundError(msg)
    except pyvips.Error:
        msg = "Failed to process image"
        raise BadRequestError(msg)

    await request.app.storage.put_thumbnail(
        processed_image.hash, body=processed_image.output
    )

    return processed_image


class ProcessedThumbnail(NamedTuple):
    output: bytes
    hash: str


class UploadChunk(TypedDict):
    index: int
    url: str
    size: int


class MultipartChunks(NamedTuple):
    size: int
    chunks: Iterator[int]


class MultipartUpload(BaseModel, frozen=True):
    upload_id: str
    chunk_size: int
    chunks: list[UploadChunk]


class MultipartUploadChunks(NamedTuple):
    chunk_index: int
    etag: str


class StorageClient:
    def __init__(
        self,
        config: StorageConfig,
        *,
        client: S3Client,
        presign_client: S3Client,
        glide: GlideManager,
    ) -> None:
        self.bucket = config.bucket
        self.client = client
        self.presign_client = presign_client

        self.base_thumbnail_url = config.public["url"]

        self._config = config
        self._cache = ValkeyCache(
            glide.client,
            namespace="media:get-url",
            serializer=ORJSONSerializer(),
        )

    def _build_key(self, media_hash: str, content_type: str) -> str:
        ext = mimetypes.guess_extension(content_type)
        return f"media/{media_hash}{ext}"

    def _build_thumbnail_key(self, media_hash: str) -> str:
        return f"thumbnails/{media_hash}.webp"

    # Same approach as this: https://stackoverflow.com/a/42179163
    def _build_multipart(self, size: int) -> MultipartChunks:
        chunk_size = max(
            (size + _TARGET_BUCKET - 1) // _TARGET_BUCKET * _ONE_MIB,
            _S3_MIN_CHUNK_SIZE,
        )
        full, tail = divmod(size, chunk_size)
        return MultipartChunks(
            size=chunk_size,
            chunks=itertools.chain(
                itertools.repeat(chunk_size, full), (tail,) if tail else ()
            ),
        )

    async def upload(self, media_hash: str, *, content_type: str) -> str:
        """Generate a presigned PUT URL for a single-request upload.

        Args:
            media_hash (str): BLAKE3 content-address hash of the file.
            content_type (str): MIME type of the file.

        Returns:
            str: Presigned URL the client uses to PUT the bytes directly.
        """
        return await self.presign_client.generate_presigned_url(
            "put_object",
            Params={
                "Bucket": self.bucket,
                "Key": self._build_key(media_hash, content_type),
                "ContentType": content_type,
            },
            ExpiresIn=_PRESIGN_PUT_TTL,
        )

    async def init_multipart(
        self, media_hash: str, *, content_type: str, size: int
    ) -> MultipartUpload:
        """Initiate a multipart upload and presign per-part PUT URLs.

        Args:
            media_hash (str): BLAKE3 content-address hash of the file.
            content_type (str): MIME type of the file.
            size (int): Total file size in bytes, used to derive chunk count.

        Returns:
            MultipartUpload: Bundle of the upload id and the presigned per-part URLs.
        """
        chunk_size, chunks = self._build_multipart(size)
        key = self._build_key(media_hash, content_type)
        response = await self.client.create_multipart_upload(
            Bucket=self.bucket, Key=key, ContentType=content_type
        )

        params = {"Bucket": self.bucket, "Key": key, "UploadId": response["UploadId"]}

        processed_chunks = [
            UploadChunk(
                index=index,
                url=(
                    await self.presign_client.generate_presigned_url(
                        "upload_part",
                        Params={**params, "PartNumber": index},
                        ExpiresIn=_PRESIGN_PUT_TTL,
                    )
                ),
                size=chunk_bytes,
            )
            for index, chunk_bytes in enumerate(chunks, start=1)
        ]

        return MultipartUpload(
            upload_id=response["UploadId"],
            chunk_size=chunk_size,
            chunks=processed_chunks,
        )

    async def finish_multipart(
        self,
        media_hash: str,
        *,
        upload_id: str,
        content_type: str,
        chunks: list[MultipartUploadChunks],
    ) -> None:
        """Complete a multipart upload by stitching the previously-uploaded parts.

        Args:
            media_hash (str): BLAKE3 content-address hash of the file.
            upload_id (str): Multipart upload id returned by `init_multipart`.
            content_type (str): MIME type of the file.
            chunks (list[MultipartUploadChunks]): Part numbers paired with the ETags returned for each `upload_part` call.
        """
        await self.client.complete_multipart_upload(
            Bucket=self.bucket,
            Key=self._build_key(media_hash, content_type),
            UploadId=upload_id,
            MultipartUpload={
                "Parts": [{"PartNumber": index, "ETag": etag} for index, etag in chunks]
            },
        )

    async def cancel_multipart(
        self, upload_id: str, media_hash: str, *, content_type: str
    ) -> None:
        """Abort a multipart upload and discard any parts already uploaded.

        Args:
            upload_id (str): Multipart upload id returned by `init_multipart`.
            media_hash (str): BLAKE3 content-address hash of the file.
            content_type (str): MIME type of the file.
        """
        await self.client.abort_multipart_upload(
            Bucket=self.bucket,
            Key=self._build_key(media_hash, content_type),
            UploadId=upload_id,
        )

    async def head(
        self,
        media_hash: str,
        *,
        content_type: str,
    ) -> HeadObjectOutputTypeDef:
        """Fetch the stored object's metadata for size or ETag verification.

        Args:
            media_hash (str): BLAKE3 content-address hash of the file.
            content_type (str): MIME type of the file.

        Returns:
            HeadObjectOutputTypeDef: S3 HeadObject response payload.
        """
        return await self.client.head_object(
            Bucket=self.bucket,
            Key=self._build_key(media_hash, content_type),
        )

    async def put_bytes(
        self, media_hash: str, body: bytes, *, content_type: str
    ) -> None:
        """Write a buffer to storage at the derived key.

        Args:
            media_hash (str): BLAKE3 content-address hash of the buffer.
            content_type (str): MIME type for the new object.
            body (bytes): Raw bytes to store.
        """
        await self.client.put_object(
            Bucket=self.bucket,
            Key=self._build_key(media_hash, content_type),
            ContentType=content_type,
            Body=body,
        )

    async def put_thumbnail(self, media_hash: str, *, body: bytes) -> None:
        """Upload encoded WebP thumbnail bytes to the public bucket.

        Args:
            media_hash (str): BLAKE3 hex digest of the thumbnail bytes, used as the object key.
            body (bytes): Encoded WebP bytes to upload.
        """
        await self.client.put_object(
            Bucket=self._config.public["bucket"],
            Key=self._build_thumbnail_key(media_hash),
            Body=body,
            ContentType="image/webp",
            CacheControl="public, max-age=31536000, immutable",
        )

    async def delete_thumbnail(self, media_hash: str) -> None:
        """Remove a thumbnail object from the public bucket.

        Args:
            media_hash (str): BLAKE3 hex digest identifying the thumbnail object.
        """
        await self.client.delete_object(
            Bucket=self._config.public["bucket"],
            Key=self._build_thumbnail_key(media_hash),
        )

    async def delete(self, media_hash: str, *, content_type: str) -> None:
        """Remove the object from storage.

        Args:
            media_hash (str): BLAKE3 content-address hash of the file.
            content_type (str): MIME type of the file.
        """
        await self.client.delete_object(
            Bucket=self.bucket,
            Key=self._build_key(media_hash, content_type),
        )

    @cached_method("_cache", ttl=_GET_URL_CACHE_TTL, noself=True)
    async def get_url(self, media_hash: str, content_type: str) -> str:
        """Return a presigned GET URL for the object, cached in Valkey.

        Args:
            media_hash (str): BLAKE3 content-address hash of the file.
            content_type (str): MIME type of the file.

        Returns:
            str: Presigned GET URL the client can use to read the object.
        """
        return await self.presign_client.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": self.bucket,
                "Key": self._build_key(media_hash, content_type),
            },
            ExpiresIn=_PRESIGN_GET_TTL,
        )

    def get_thumbnail_url(self, media_hash: str) -> str:
        """Obtains the url for the thumbnail

        Args:
            media_hash (str): BLAKE3 content-address hash of the file.

        Returns:
            str: Complete public thumbnail URL
        """
        return f"{self.base_thumbnail_url}/{self._build_thumbnail_key(media_hash)}"


### Sudo operations


class SudoClient:
    def __init__(self, pool: asyncpg.Pool) -> None:
        self.pool = pool
        self.ttl = datetime.timedelta(minutes=10)

    async def grant(self, member_id: str, *, reason: str) -> datetime.datetime:
        """Elevate a member to sudo for the configured TTL, recording the grant.

        Args:
            member_id (str): Kratos identity UUID of the member being elevated.
            reason (str): Operator-supplied justification for breaking the
                glass. Recorded on both the live grant and the audit row.

        Returns:
            datetime.datetime: The UTC instant at which the elevation expires
            (`now()` plus the client's `ttl`).
        """
        query = """
        WITH upserted AS (
            INSERT INTO sudo_grants (member_id, expires_at, reason)
            VALUES ($1, now() + $2, $3)
            ON CONFLICT (member_id) DO UPDATE
                SET granted_at = now(),
                    expires_at = now() + $2,
                    reason     = EXCLUDED.reason
            RETURNING granted_at, expires_at
        ), logged AS (
            INSERT INTO sudo_audit (member_id, reason, granted_at, expires_at)
            SELECT $1, $3, granted_at, expires_at FROM upserted
        )
        SELECT expires_at FROM upserted;
        """
        return await self.pool.fetchval(query, member_id, self.ttl, reason)

    async def revoke(self, member_id: str) -> None:
        """Revoke a member's sudo elevation immediately.

        Args:
            member_id (str): Kratos identity UUID whose active grant should be
                cleared.
        """
        query = """
        DELETE FROM sudo_grants
        WHERE member_id = $1;
        """
        await self.pool.execute(query, member_id)

    async def get_expiry(self, member_id: str) -> Optional[datetime.datetime]:
        """Return when a member's *active* sudo grant expires, if any.

        Args:
            member_id (str): Kratos identity UUID to look up.

        Returns:
            Optional[datetime.datetime]: The grant's UTC expiry instant, or
            `None` when the member has no grant or it has already expired
            (`expires_at > now()` filters out stale rows).
        """
        query = """
        SELECT expires_at FROM sudo_grants
        WHERE member_id = $1 AND expires_at > now();
        """
        return await self.pool.fetchval(query, member_id)

    async def is_active(self, member_id: str) -> bool:
        """Check whether a member currently holds an unexpired sudo grant.

        Args:
            member_id (str): Kratos identity UUID to check.

        Returns:
            bool: `True` if an unexpired grant exists, `False` otherwise.
        """
        query = """
            SELECT EXISTS (
                SELECT 1 FROM sudo_grants
                WHERE member_id = $1 AND expires_at > now()
            );
        """
        return await self.pool.fetchval(query, member_id)


### Prometheus instrumentator


class PrometheusMiddleware:
    """Middleware layer for the Prometheus instrumentator

    Args:
        app (Kanae): Instance of the application, which is `Kanae`
        settings (InstrumentatorSettings): Instance of `InstrumentatorSettings`
        round_latency_decimals (int, optional): The amount of decimals to round up to for latency values. Defaults to 4
        should_only_respect_2xx_for_higher (bool, optional): Whether to only respect 2xx or higher requests. Defaults to False
        excluded_handlers (list[str], optional): List of excluded handlers. Defaults to an empty list
        body_handlers (list[str], optional): List of body handlers. Defaults to an empty list
        instrumentations (Sequence[Callable[[metrics.Info], None]], optional): List of instrumentation functions to use. Defaults to an empty sequence
        async_instrumentations (Sequence[Callable[[metrics.Info], Awaitable[None]]], optional): List of instrumentation coroutines to use. Defaults to an empty sequence
        latency_higher_buckets (Sequence[Union[float, str]], optional): Optional sequence of buckets for higher latency. Defaults to `LATENCY_HIGHER_BUCKETS`, which is a predefined constant
        latency_lower_buckets (Sequence[Union[float, str]], optional): Optional sequence of buckets for lower latency. Defaults to `LATENCY_LOWER_BUCKETS`, which is a predefined constant
        registry (Optional[CollectorRegistry], optional): A optional provided registry to utilize instead. Defaults to None
        custom_labels (Optional[dict], optional): Any custom labels to use within each metric. Defaults to None
    """

    def __init__(
        self,
        app: Kanae,
        *,
        settings: InstrumentatorSettings,
        round_latency_decimals: int = 4,
        should_only_respect_2xx_for_higher: bool = False,
        excluded_handlers: Sequence[re.Pattern[str] | str] = (),
        body_handlers: Sequence[re.Pattern[str] | str] = (),
        instrumentations: Sequence[Callable[[metrics.Info], None]] = (),
        async_instrumentations: Sequence[
            Callable[[metrics.Info], Awaitable[None]]
        ] = (),
        latency_higher_buckets: Sequence[float | str] = LATENCY_HIGHER_BUCKETS,
        latency_lower_buckets: Sequence[float | str] = LATENCY_LOWER_BUCKETS,
        registry: CollectorRegistry = REGISTRY,
        custom_labels: Optional[dict] = None,
    ) -> None:
        self.app = app

        self.should_group_status_codes = settings.should_group_status_codes
        self.should_ignore_not_templated = settings.should_ignore_not_templated
        self.should_group_not_templated = settings.should_group_not_templated
        self.should_round_latency_decimals = settings.should_round_latency_decimals
        self.should_instrument_requests_in_progress = (
            settings.should_instrument_requests_in_progress
        )

        self.round_latency_decimals = round_latency_decimals
        self.in_progress_name = settings.in_progress_name
        self.in_progress_labels = settings.in_progress_labels
        self.registry = registry
        self.custom_labels = custom_labels or {}

        self.excluded_handlers = [re.compile(path) for path in excluded_handlers]
        self.body_handlers = [re.compile(path) for path in body_handlers]

        if instrumentations:
            self.instrumentations = instrumentations
        else:
            default_instrumentation = metrics.default(
                should_only_respect_2xx_for_highr=should_only_respect_2xx_for_higher,
                latency_highr_buckets=latency_higher_buckets,
                latency_lowr_buckets=latency_lower_buckets,
                registry=self.registry,
                custom_labels=self.custom_labels,
                metric_namespace=settings.metric_namespace,
                metric_subsystem=settings.metric_subsystem,
                should_exclude_streaming_duration=settings.should_exclude_streaming_duration,
            )
            if default_instrumentation:
                self.instrumentations = [default_instrumentation]
            else:
                self.instrumentations = []

        self.async_instrumentations = async_instrumentations

        self.in_progress: Optional[Gauge] = None
        if self.should_instrument_requests_in_progress:
            labels = (
                (
                    "method",
                    "handler",
                )
                if self.in_progress_labels
                else ()
            )
            self.in_progress = Gauge(
                name=self.in_progress_name,
                documentation="Number of HTTP requests in progress.",
                labelnames=labels,
            )

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        request = Request(scope)
        start_time = time.perf_counter()

        handler, is_templated = self._get_handler(request)
        is_excluded = self._is_handler_excluded(handler, is_templated=is_templated)
        handler = (
            "none" if not is_templated and self.should_group_not_templated else handler
        )

        if not is_excluded and self.in_progress:
            in_progress = (
                self.in_progress.labels(request.method, handler)
                if self.in_progress_labels
                else self.in_progress
            )
            in_progress.inc()
        else:
            in_progress = None

        status_code = 500
        headers = []
        body = b""
        response_start_time = None

        collect_body = any(pattern.search(handler) for pattern in self.body_handlers)

        async def send_wrapper(message: Message) -> None:
            nonlocal status_code, headers, response_start_time, body
            if message["type"] == "http.response.start":
                headers = message["headers"]
                status_code = message["status"]
                response_start_time = time.perf_counter()
            elif (
                collect_body
                and message["type"] == "http.response.body"
                and message["body"]
            ):
                body += message["body"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except Exception:  # noqa: BLE001
            return await self.app(scope, receive, send_wrapper)
        else:
            if not is_excluded:
                await self._record_metrics(
                    request,
                    handler,
                    status_code,
                    headers,
                    body,
                    start_time,
                    response_start_time,
                    in_progress,
                )

    async def _record_metrics(
        self,
        request: Request,
        handler: str,
        status_code: int,
        headers: list,
        body: bytes,
        start_time: float,
        response_start_time: Optional[float],
        in_progress: Optional[Gauge],
    ) -> None:
        status = str(status_code)
        duration = max(time.perf_counter() - start_time, 0.0)
        duration_without_streaming = 0.0

        if response_start_time:
            duration_without_streaming = max(response_start_time - start_time, 0.0)

        if self.should_instrument_requests_in_progress:
            in_progress.dec()  # ty: ignore[unresolved-attribute]

        if self.should_round_latency_decimals:
            duration = round(duration, self.round_latency_decimals)
            duration_without_streaming = round(
                duration_without_streaming, self.round_latency_decimals
            )

        status = status[0] + "xx" if self.should_group_status_codes else status

        response = Response(
            content=body, headers=Headers(raw=headers), status_code=status_code
        )

        info = metrics.Info(
            request=request,
            response=response,
            method=request.method,
            modified_handler=handler,
            modified_status=status,
            modified_duration=duration,
            modified_duration_without_streaming=duration_without_streaming,
        )

        for instrumentation in self.instrumentations:
            instrumentation(info)

        await asyncio.gather(
            *[instrumentation(info) for instrumentation in self.async_instrumentations]
        )

    def _get_handler(self, request: Request) -> tuple[str, bool]:
        """Extracts either template or (if no template) path.

        Args:
            request (Request): Instance of `Request`

        Returns:
            Tuple[str, bool]: Tuple with two elements. First element is either
                template or if no template the path. Second element tells you
                if the path is templated or not.
        """
        route_name = routing.get_route_name(request)
        return route_name or request.url.path, bool(route_name)

    def _is_handler_excluded(self, handler: str, *, is_templated: bool) -> bool:
        """Determines if the handler should be ignored.

        Args:
            handler (str): Handler that handles the request.
            is_templated (bool): Shows if the request is templated.

        Returns:
            bool: `True` if excluded, `False` if not.
        """

        if not is_templated and self.should_ignore_not_templated:
            return True

        return bool(any(pattern.search(handler) for pattern in self.excluded_handlers))


class PrometheusInstrumentator:
    """Instrumentator that exports Prometheus metrics for consumption

    Args:
        app (Kanae): Instance of the application, which is `Kanae`
        settings (InstrumentatorSettings): Instance of `InstrumentatorSettings`
        round_latency_decimals (int, optional): The amount of decimals to round up to for latency values. Defaults to 4
        excluded_handlers (list[str], optional): List of excluded handlers. Defaults to an empty list
        body_handlers (list[str], optional): List of body handlers. Defaults to an empty list
        registry (Optional[CollectorRegistry], optional): A optional provided registry to utilize instead. Defaults to None
    """

    def __init__(
        self,
        app: Kanae,
        *,
        settings: InstrumentatorSettings,
        round_latency_decimals: int = 4,
        excluded_handlers: list[str] | None = None,
        body_handlers: list[str] | None = None,
        registry: Optional[CollectorRegistry] = None,
    ) -> None:
        if body_handlers is None:
            body_handlers = []
        if excluded_handlers is None:
            excluded_handlers = []
        self.app = app
        self.settings = settings

        self.should_group_status_codes = settings.should_group_status_codes
        self.should_ignore_not_templated = settings.should_ignore_not_templated
        self.should_group_not_templated = settings.should_group_not_templated
        self.should_round_latency_decimals = settings.should_round_latency_decimals
        self.should_instrument_requests_in_progress = (
            settings.should_instrument_requests_in_progress
        )
        self.should_exclude_streaming_duration = (
            settings.should_exclude_streaming_duration
        )

        self.in_progress_name = settings.in_progress_name
        self.in_progress_labels = settings.in_progress_labels
        self.metric_namespace = settings.metric_namespace
        self.metric_subsystem = settings.metric_subsystem

        self.round_latency_decimals = round_latency_decimals
        self.registry = registry or REGISTRY

        self.excluded_handlers = [re.compile(path) for path in excluded_handlers]
        self.body_handlers = [re.compile(path) for path in body_handlers]
        self.instrumentations: list[Callable[[metrics.Info], None]] = []
        self.async_instrumentations: list[
            Callable[[metrics.Info], Awaitable[None]]
        ] = []

    def add_middleware(
        self,
        *,
        should_only_respect_2xx_for_higher: bool = False,
        latency_higher_buckets: Sequence[float | str] = LATENCY_HIGHER_BUCKETS,
        latency_lower_buckets: Sequence[float | str] = LATENCY_LOWER_BUCKETS,
    ) -> None:
        """Injects the middleware into the application

        Args:
            should_only_respect_2xx_for_higher (bool, optional): Whether to only respect 2xx or higher requests. Defaults to False
            latency_higher_buckets (Sequence[Union[float, str]], optional): Optional sequence of buckets for higher latency. Defaults to `LATENCY_HIGHER_BUCKETS`, which is a predefined constant
            latency_lower_buckets (Sequence[Union[float, str]], optional): Optional sequence of buckets for lower latency. Defaults to `LATENCY_LOWER_BUCKETS`, which is a predefined constant
        """
        self.app.add_middleware(
            PrometheusMiddleware,  # ty: ignore[invalid-argument-type]
            settings=self.settings,
            round_latency_decimals=self.round_latency_decimals,
            instrumentations=self.instrumentations,
            async_instrumentations=self.async_instrumentations,
            excluded_handlers=self.excluded_handlers,
            body_handlers=self.body_handlers,
            should_only_respect_2xx_for_higher=should_only_respect_2xx_for_higher,
            latency_higher_buckets=latency_higher_buckets,
            latency_lower_buckets=latency_lower_buckets,
            registry=self.registry,
        )

    def add(
        self,
        *instrumentation_function: Optional[
            Callable[[metrics.Info], None | Awaitable[None]]
        ],
    ) -> None:
        """Adds a function to list of instrumentations

        Args:
            instrumentation_function (Optional[Callable[[metrics.Info], Union[None, Awaitable[None]]]]): Function
                that will be executed during every request handler call (if
                not excluded). See above for detailed information on the
                interface of the function.
        """

        for func in instrumentation_function:
            if func:
                if asyncio.iscoroutinefunction(func):
                    self.async_instrumentations.append(
                        cast(
                            "Callable[[metrics.Info], Awaitable[None]]",
                            func,
                        )
                    )
                else:
                    self.instrumentations.append(
                        cast("Callable[[metrics.Info], None]", func)
                    )

    def start(
        self,
        endpoint: str = "/metrics",
        *,
        include_in_schema: bool = False,
        methods: list[str] | None = None,
        name: str | None = None,
    ) -> None:
        """Starts the instrumentator by injecting the metrics route into the application

        Args:
            endpoint (str, optional): The path of the endpoint to serve. Defaults to "/metrics".
            include_in_schema (bool, optional): Whether to include the endpoint into the OpenAPI definitions. Defaults to False.
            methods (list[str] | None, optional): The HTTP methods to allow. Defaults to None.
            name (str | None, optional): The name of the route. Defaults to None.
        """

        def metrics(request: Request) -> Response:
            ephemeral_registry = self.registry

            resp = Response(content=generate_latest(ephemeral_registry))
            resp.headers["Content-Type"] = CONTENT_TYPE_LATEST

            return resp

        self.app.add_route(
            path=endpoint,
            route=metrics,
            include_in_schema=include_in_schema,
            methods=methods,
            name=name,
        )


### FastAPI subclass (Kanae)
class Kanae(FastAPI):
    pool: asyncpg.Pool
    session: aiohttp.ClientSession
    storage: StorageClient
    glide: GlideManager

    limiter: KanaeLimiter
    ory: OryClient
    sudo: SudoClient

    def __init__(
        self,
        *,
        config: KanaeConfig,
    ) -> None:
        super().__init__(
            title=__title__,
            description=__description__,
            version=__version__,
            dependencies=[Depends(self.get_db)],
            default_response_class=ORJSONResponse,
            redoc_url="/docs",
            docs_url=None,
            lifespan=self.lifespan,
        )

        self._boto_session = AioSession()
        self._logger = logging.getLogger("kanae.core")

        self.config = config
        self.is_prometheus_enabled: bool = config.kanae.prometheus["enabled"]

        _instrumentator_settings = InstrumentatorSettings(metric_namespace="kanae")
        self.instrumentator = PrometheusInstrumentator(
            self, settings=_instrumentator_settings
        )

        _sync_boto_session = Session()
        self.sync_storage: BotoS3Client = _sync_boto_session.create_client(
            "s3",
            endpoint_url=self.config.storage.url,
            region_name=self.config.storage.region,
            aws_access_key_id=self.config.storage.key_id,
            aws_secret_access_key=self.config.storage.secret_key,
            config=BotoConfig(signature_version="s3v4"),
        )  # ty:ignore[invalid-assignment]

        self.ph = PasswordHasher()

        self.add_exception_handler(
            HTTPException,
            self.http_exception_handler,  # ty: ignore[invalid-argument-type]
        )
        self.add_exception_handler(
            RequestValidationError,
            self.request_validation_error_handler,  # ty: ignore[invalid-argument-type]
        )
        self.add_exception_handler(
            VerificationError,
            self.verification_error_handler,  # ty: ignore[invalid-argument-type]
        )
        self.add_exception_handler(
            InvalidHashError,
            self.invalid_hash_error_handler,  # ty: ignore[invalid-argument-type]
        )
        self.add_exception_handler(
            RateLimitExceeded,
            rate_limit_exceeded_handler,  # ty: ignore[invalid-argument-type]
        )

        if self.is_prometheus_enabled:
            _host = self.config.kanae.prometheus["host"]
            _port = self.config.kanae.prometheus["port"]

            self.instrumentator.start()

            self._logger.info(
                "Prometheus server started on %s:%d/metrics", _host, _port
            )

    ### Exception Handlers

    def http_exception_handler(
        self, request: RouteRequest, exc: HTTPException
    ) -> Response:
        headers = getattr(exc, "headers", None)
        if not is_body_allowed_for_status_code(exc.status_code):
            return Response(status_code=exc.status_code, headers=headers)
        message = HTTPExceptionResponse(detail=exc.detail)
        return ORJSONResponse(
            content=message.model_dump(), status_code=exc.status_code, headers=headers
        )

    def request_validation_error_handler(
        self, request: RouteRequest, exc: RequestValidationError
    ) -> Response:
        errors = [
            {key: value for key, value in error.items() if key not in {"ctx", "url"}}
            for error in exc.errors()
        ]
        message = RequestValidationErrorResponse(errors=errors)
        self._logger.warning("Request Validation Error! Message:\n%s", errors)
        return ORJSONResponse(
            content=message.model_dump(),
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        )

    def verification_error_handler(
        self, request: RouteRequest, exc: VerificationError
    ) -> ORJSONResponse:
        return ORJSONResponse(
            content={"error": "Failed to verify, entirely invalid hash"},
            status_code=status.HTTP_403_FORBIDDEN,
        )

    def invalid_hash_error_handler(
        self, request: RouteRequest, exc: InvalidHashError
    ) -> ORJSONResponse:
        self._logger.error("Encountered a malformed stored argon2 hash: %s", exc)
        return ORJSONResponse(
            content={"error": "Stored attendance hash is malformed"},
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )

    ### Server-related utilities

    @asynccontextmanager
    async def lifespan(self, app: Self) -> AsyncGenerator[None]:
        async with (
            asyncpg.create_pool(dsn=self.config.postgres_uri, init=init) as app.pool,
            aiohttp.ClientSession() as app.session,  # ty: ignore[invalid-assignment],
            GlideManager(uri=app.limiter.storage_uri) as app.glide,
            self._boto_session.create_client(
                "s3",
                endpoint_url=self.config.storage.url,
                region_name=self.config.storage.region,
                aws_access_key_id=self.config.storage.key_id,
                aws_secret_access_key=self.config.storage.secret_key,
                config=AioConfig(signature_version="s3v4"),
            ) as s3_client,
            self._boto_session.create_client(
                "s3",
                endpoint_url=self.config.storage.presign_url,
                region_name=self.config.storage.region,
                aws_access_key_id=self.config.storage.key_id,
                aws_secret_access_key=self.config.storage.secret_key,
                config=AioConfig(
                    signature_version="s3v4", s3={"addressing_style": "path"}
                ),
            ) as presign_s3_client,
        ):
            app.ory = OryClient(self.config.ory, session=app.session, glide=app.glide)
            app.storage = StorageClient(
                self.config.storage,
                client=s3_client,
                presign_client=presign_s3_client,
                glide=app.glide,
            )
            self.sudo = SudoClient(app.pool)
            app.limiter.attach(app.glide)

            yield

    def get_db(self) -> Generator[asyncpg.Pool, None, None]:
        yield self.pool

    def openapi(self) -> dict[str, Any]:
        if not self.openapi_schema:
            self.openapi_schema = get_openapi(
                title=self.title,
                version=self.version,
                openapi_version=self.openapi_version,
                description=self.description,
                terms_of_service=self.terms_of_service,
                contact=self.contact,
                license_info=self.license_info,
                routes=self.routes,
                tags=self.openapi_tags,
                servers=self.servers,
            )
            for path in self.openapi_schema["paths"].values():
                for method in path.values():
                    responses = method.get("responses")
                    if str(status.HTTP_422_UNPROCESSABLE_CONTENT) in responses:
                        del responses[str(status.HTTP_422_UNPROCESSABLE_CONTENT)]
        return self.openapi_schema
