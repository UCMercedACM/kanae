from __future__ import annotations

from typing import TYPE_CHECKING, Optional, Self, TypedDict, Unpack

from glide import (
    AdvancedGlideClientConfiguration,
    BackoffStrategy,
    CompressionConfiguration,
    GlideClient,
    GlideClientConfiguration,
    NodeAddress,
    ProtocolVersion,
    ReadFrom,
    ServerCredentials,
)
from limits._storage_scheme import parse_storage_uri

if TYPE_CHECKING:
    from types import TracebackType


class GlideKwargs(TypedDict, total=False):
    read_from: ReadFrom
    request_timeout: Optional[int]
    reconnect_strategy: Optional[BackoffStrategy]
    client_name: Optional[str]
    protocol: ProtocolVersion
    pubsub_subscriptions: Optional[GlideClientConfiguration.PubSubSubscriptions]
    inflight_requests_limit: Optional[int]
    client_az: Optional[str]
    advanced_config: Optional[AdvancedGlideClientConfiguration]
    lazy_connect: Optional[bool]
    compression: Optional[CompressionConfiguration]
    read_only: bool


class GlideManager:
    """Async context manager owning the lifecycle of a :class:`glide.GlideClient`.

    :param uri: uri of the form:

     - ``async+valkey://[:password]@host:port``
     - ``async+valkey://[:password]@host:port/db``
     - ``async+valkeys://[:password]@host:port``
     - ``async+redis://[:password]@host:port``

     The URI is parsed to build a :class:`glide.GlideClientConfiguration`.
    :param kwargs: keyword arguments forwarded to
     :class:`glide.GlideClientConfiguration` (e.g. ``request_timeout``,
     ``client_name``, ``protocol``).
    """

    def __init__(self, uri: str, **kwargs: Unpack[GlideKwargs]) -> None:
        self.uri = uri
        options_from_uri = parse_storage_uri(uri)

        addresses = [
            NodeAddress(host=host, port=int(port))
            for host, port in options_from_uri.locations
        ] or [NodeAddress()]

        credentials = (
            ServerCredentials(
                username=options_from_uri.username or None,
                password=options_from_uri.password or "",
            )
            if options_from_uri.username or options_from_uri.password
            else None
        )

        path = (options_from_uri.path or "").lstrip("/")
        database_id = int(path) if path.isdigit() else None

        self._config = GlideClientConfiguration(
            addresses=addresses,
            use_tls=uri.startswith(("rediss://", "valkeys://")),
            credentials=credentials,
            database_id=database_id,
            **kwargs,
        )
        self._client: Optional[GlideClient] = None

    async def __aenter__(self) -> Self:
        self._client = await GlideClient.create(self._config)
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        if self._client is not None:
            await self._client.close()
            self._client = None

    @property
    def client(self) -> GlideClient:
        if self._client is None:
            msg = "GlideManager is not entered; use 'async with' first."
            raise RuntimeError(msg)
        return self._client
