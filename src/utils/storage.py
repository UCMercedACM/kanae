from __future__ import annotations

import itertools
import mimetypes
from typing import TYPE_CHECKING, NamedTuple, TypedDict

from pydantic import BaseModel

from utils.cache import ORJSONSerializer, ValkeyCache, cached_method

if TYPE_CHECKING:
    from collections.abc import Iterator

    from types_aiobotocore_s3 import S3Client
    from types_aiobotocore_s3.type_defs import HeadObjectOutputTypeDef

    from core import StorageConfig
    from utils.glide import GlideManager

_PRESIGN_PUT_TTL = 900  # 15 min
_PRESIGN_GET_TTL = 300  # 5 min
_GET_URL_CACHE_TTL = max(_PRESIGN_GET_TTL - 30, 30)

_S3_MIN_CHUNK_SIZE = 5 * 1024 * 1024
_TARGET_CHUNK_COUNT = 128
_ONE_MIB = 1024 * 1024
_TARGET_BUCKET = _TARGET_CHUNK_COUNT * _ONE_MIB  # one MiB-step per bucket of file size


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
        self, config: StorageConfig, *, client: S3Client, glide: GlideManager
    ) -> None:

        self._config = config

        self.bucket = config.bucket
        self.client = client

        self.cache = ValkeyCache(
            glide.client,
            namespace="media:get-url",
            serializer=ORJSONSerializer(),
        )

    def _build_key(self, media_hash: str, content_type: str) -> str:
        ext = mimetypes.guess_extension(content_type)
        return f"media/{media_hash}{ext}"

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
        return await self.client.generate_presigned_url(
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
                    await self.client.generate_presigned_url(
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
        return await self.client.head_object(
            Bucket=self.bucket,
            Key=self._build_key(media_hash, content_type),
        )

    async def delete(self, media_hash: str, *, content_type: str) -> None:
        await self.client.delete_object(
            Bucket=self.bucket,
            Key=self._build_key(media_hash, content_type),
        )

    @cached_method("cache", ttl=_GET_URL_CACHE_TTL, noself=True)
    async def get_url(self, media_hash: str, content_type: str) -> str:
        return await self.client.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": self.bucket,
                "Key": self._build_key(media_hash, content_type),
            },
            ExpiresIn=_PRESIGN_GET_TTL,
        )
