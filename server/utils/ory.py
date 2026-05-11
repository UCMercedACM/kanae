import datetime
import logging
import uuid
from typing import Any, TypedDict, Unpack, cast

import aiohttp
import orjson
from aiocache.plugins import HitMissRatioPlugin
from aiohttp.client import _RequestOptions
from blake3 import blake3
from fastapi import status
from pydantic import BaseModel
from utils.cache import ORJSONSerializer, PydanticSerializer, ValkeyCache, cached_method
from utils.errors import (
    BadGatewayError,
    ConflictError,
    ServiceUnavailableError,
)
from utils.glide import GlideManager
from yarl import URL

### Structs / TypedDicts


class SubjectSet(TypedDict):
    namespace: str
    object: str
    relation: str


class IdentityTraits(TypedDict):
    email: str
    name: str
    display_name: str


class KratosIdentity(BaseModel, frozen=True):
    id: str
    schema_id: str
    traits: dict[str, Any]

    @property
    def email(self) -> str:
        return self.traits["email"]

    @property
    def name(self) -> str:
        return self.traits["name"]

    @property
    def display_name(self) -> str:
        return self.traits["display_name"]


class KanaeSession(BaseModel, frozen=True):
    id: uuid.UUID
    active: bool
    expires_at: datetime.datetime
    authenticated_at: datetime.datetime
    issued_at: datetime.datetime
    identity: KratosIdentity


class OryConfig(BaseModel, frozen=True):
    kratos_public_url: str
    kratos_admin_url: str
    keto_read_url: str
    keto_write_url: str
    kratos_webhook_master_key: str


### Utilities


class Service:
    """Callable URL builder bound to a service base.

    Args:
        base (str): Base URL
    """

    __slots__ = ("base",)

    def __init__(self, base: str) -> None:
        self.base = URL(base)

    def __call__(self, path: str, **parameters: object) -> URL:
        """Build a URL: `service("admin/identities/{id}", id=42)` → `base/admin/identities/42`."""
        return self.base.joinpath(
            *(segment.format_map(parameters) for segment in path.split("/") if segment)
        )


### Client


class OryClient:
    """Wire OryClient up against the running app's shared resources.

    Args:
        config: Ory service URLs (Kratos public/admin, Keto read/write).
        session: Shared aiohttp session used for every upstream call.
        glide: Open Valkey GLIDE connection used by the per-method
            caches; the underlying `GlideClient` is taken from
            `glide.client`.
    """

    def __init__(
        self, config: OryConfig, *, session: aiohttp.ClientSession, glide: GlideManager
    ) -> None:
        self.config = config
        self.session = session
        self.glide = glide.client

        self.kratos_public = Service(config.kratos_public_url)
        self.kratos_admin = Service(config.kratos_admin_url)
        self.keto_read = Service(config.keto_read_url)
        self.keto_write = Service(config.keto_write_url)

        self._whoami_cache = ValkeyCache(
            self.glide,
            namespace="ory:whoami:",
            serializer=PydanticSerializer(KanaeSession),
            plugins=[HitMissRatioPlugin()],
        )
        self._identity_cache = ValkeyCache(
            self.glide,
            namespace="ory:identity",
            serializer=PydanticSerializer(KratosIdentity),
            plugins=[HitMissRatioPlugin()],
        )
        self._check_cache = ValkeyCache(
            self.glide,
            namespace="ory:check",
            serializer=ORJSONSerializer(),
            plugins=[HitMissRatioPlugin()],
        )

        self._logger = logging.getLogger("kanae.ory")

    ### Internal utilities

    @staticmethod
    def _whoami_key(_func: object, _self: object, cookie: str) -> str:
        return blake3(cookie.encode("utf-8")).hexdigest()

    @staticmethod
    def _identity_key(_func: object, _self: object, identity_id: str) -> str:
        return identity_id

    @staticmethod
    def _check_key(
        _func: object,
        _self: object,
        namespace: str,
        resource: str,
        relation: str,
        subject_id: str,
    ) -> str:
        return f"{namespace}:{resource}:{relation}:{subject_id}"

    async def _invalidate_resource(self, namespace: str, resource: str) -> None:
        prefix = f"ory:check:{namespace}:{resource}"
        await self._check_cache.clear(namespace=prefix)

    async def _request(
        self, method: str, url: URL, **kwargs: Unpack[_RequestOptions]
    ) -> aiohttp.ClientResponse:
        response = await self.session.request(method, url, **kwargs)

        if response.status == status.HTTP_502_BAD_GATEWAY:
            raise BadGatewayError
        if response.status == status.HTTP_503_SERVICE_UNAVAILABLE:
            raise ServiceUnavailableError

        return response

    ### Session management

    @cached_method(cache_attr="_whoami_cache", ttl=60, key_builder=_whoami_key)
    async def whoami(self, cookie: str) -> KanaeSession | None:
        """Resolve a Kratos session for a `Cookie` request header.

        Returns `None` for invalid cookies; the auth dependency layer above
        is expected to translate `None` into a 401 response, and to
        short-circuit before calling this when the cookie is missing
        (the cache key builder runs before the function body, so an empty
        cookie would crash the key builder rather than reach this method).
        Resolved sessions are cached under a blake3 digest of the cookie
        for 60 seconds.

        Args:
            cookie: Raw value of the browser's `ory_kratos_session` cookie.
                Must be non-empty; callers are responsible for checking.

        Returns:
            The resolved :class:`KanaeSession`, or `None` if Kratos rejects
            the cookie as invalid (HTTP 401).
        """
        url = self.kratos_public("/sessions/whoami")
        response = await self._request(
            "GET", url, headers={"cookie": f"ory_kratos_session={cookie}"}
        )

        if response.status == status.HTTP_401_UNAUTHORIZED:
            await response.release()

            return None

        data = await response.json(loads=orjson.loads)

        return KanaeSession.model_validate(data)

    async def revoke_session(self, session_id: str) -> None:
        """Revoke a single Kratos session by id.

        Idempotent — Kratos returns 204 on success and accepts repeated
        revokes of the same session id without raising.

        Args:
            session_id: The Kratos session UUID, typically read from
                :attr:`KanaeSession.id`.
        """
        await self._request(
            "DELETE",
            self.kratos_admin("/admin/sessions/{session_id}", session_id=session_id),
        )

    async def revoke_all_sessions(self, identity_id: str) -> None:
        """Revoke every active Kratos session belonging to one identity.

        Use when the user changes credentials, on admin-initiated boot-out,
        or as part of a "log out everywhere" flow.

        Args:
            identity_id: The Kratos identity UUID whose sessions should
                all be invalidated.
        """
        await self._request(
            "DELETE",
            self.kratos_admin("/admin/identities/{id}/sessions", id=identity_id),
        )

    ### Identity utilities and management

    @cached_method(cache_attr="_identity_cache", ttl=360, key_builder=_identity_key)
    async def get_identity(self, identity_id: str) -> KratosIdentity | None:
        """Fetch a Kratos identity by id.

        Cached for 6 minutes, keyed on `identity_id`. The cache is
        invalidated by :meth:`update_identity_traits` on successful
        update.

        Args:
            identity_id: Kratos identity UUID.

        Returns:
            The :class:`KratosIdentity`, or `None` if Kratos returns
            404 (no such identity).
        """
        response = await self._request(
            "GET", self.kratos_admin("/admin/identities/{id}", id=identity_id)
        )

        if response.status == status.HTTP_404_NOT_FOUND:
            await response.release()

            return None

        data = await response.json(loads=orjson.loads)
        return KratosIdentity.model_validate(data)

    async def find_identity_by_email(self, email: str) -> KratosIdentity | None:
        """Look up an identity by its login-credential email.

        Under the project's identity schema (email as
        `credentials.password.identifier`) Kratos guarantees the result
        is at most one identity. Multiple matches indicate a schema or
        data issue and are logged as a warning before returning the first.

        Args:
            email: The login email registered on the identity.

        Returns:
            The matching :class:`KratosIdentity`, or `None` if no
            identity is registered with this email.
        """
        response = await self._request(
            "GET",
            self.kratos_admin("/admin/identities").with_query(
                credentials_identifier=email
            ),
        )

        data = await response.json(loads=orjson.loads)
        if len(data) > 1:
            _log = logging.getLogger("kanae.ory")
            _log.warning("More than one email has been found")

        return KratosIdentity.model_validate(data[0])

    async def update_identity_traits(
        self,
        identity_id: str,
        traits: IdentityTraits,
    ) -> KratosIdentity:
        """Replace an identity's traits and bust its cached entry.

        On success, calls :meth:`get_identity.cache_invalidate` so the
        next read reflects the new traits.

        Args:
            identity_id: Kratos identity UUID.
            traits: New trait payload to write. Replaces the existing
                traits wholesale; partial updates are not supported by
                the underlying Kratos endpoint.

        Returns:
            The updated :class:`KratosIdentity` as returned by Kratos.

        Raises:
            ConflictError: If `traits["email"]` is already bound
                to another identity (Kratos 409).
        """
        payload = {"schema_id": "person", "traits": traits}
        response = await self._request(
            "PUT",
            self.kratos_admin("/admin/identities/{id}", id=identity_id),
            json=payload,
        )

        if response.status == status.HTTP_409_CONFLICT:
            await response.release()

            msg = "Email already is bound to another identity"
            raise ConflictError(msg)

        data = await response.json(loads=orjson.loads)

        identity = KratosIdentity.model_validate(data)
        await self.get_identity.cache_invalidate(identity_id)
        return identity

    ### Permission management via Keto

    @cached_method(cache_attr="_check_cache", ttl=60, key_builder=_check_key)
    async def check_permission(
        self,
        namespace: str,
        resource: str,
        relation: str,
        subject_id: str,
    ) -> bool:
        """Ask Keto whether `subject_id` has `relation` on a resource.

        Cached for 60 seconds keyed on the full
        `(namespace, object, relation, subject)` tuple. The cache is
        invalidated for the affected `(namespace, object)` pair by
        :meth:`grant` and :meth:`revoke` via :meth:`_invalidate_resource`.

        Args:
            namespace: Resource type, e.g. `"Project"`.
            resource: Resource id (a UUID for projects, a
                role name for `Role` namespace, etc.).
            relation: Relation name, e.g. `"owners"`, `"editors"`,
                `"viewers"`, `"member"`.
            subject_id: Identity UUID being checked.

        Returns:
            `True` if Keto says the relation holds, `False` otherwise.
        """
        params = {
            "namespace": namespace,
            "object": resource,
            "relation": relation,
            "subject_id": subject_id,
        }
        response = await self._request(
            "GET", self.keto_read("/relation-tuples/check").with_query(params)
        )

        data = await response.json(loads=orjson.loads)
        return data["allowed"]

    async def revoke(
        self,
        namespace: str,
        resource: str,
        relation: str,
        *,
        subject_id: str | None = None,
        subject_set: SubjectSet | None = None,
    ) -> None:
        """Delete a Keto relation tuple.

        Idempotent — Keto returns 204 whether the tuple existed or not.
        On success, all cached :meth:`check_permission` results for the
        affected `(namespace, object)` are invalidated.

        Args:
            namespace: Resource type.
            resource: Resource id.
            relation: Relation name on the tuple to remove.
            subject_id: Direct identity-id subject. Pass exactly one of
                `subject_id` or `subject_set`.
            subject_set: Subject-set reference (e.g. `Role:admin#member`)
                — typically built via :func:`role_subject_set`. Pass
                exactly one of `subject_id` or `subject_set`.

        Raises:
            ValueError: If neither or both of `subject_id` /
                `subject_set` are provided.
        """

        def _build_revoke_payload(
            namespace: str,
            resource: str,
            relation: str,
            subject_id: str | None,
            subject_set: SubjectSet | None,
        ) -> dict[str, str]:
            if not subject_id and not subject_set:
                msg = "Pass exactly one of subject_id or subject_set"
                raise ValueError(msg)

            params: dict[str, str] = {
                "namespace": namespace,
                "object": resource,
                "relation": relation,
            }

            if subject_id:
                params["subject_id"] = subject_id
            elif subject_set is not None:
                params.update(
                    {
                        f"subject_set.{k}": v
                        for k, v in cast("dict[str, str]", subject_set).items()
                    },
                )
            return params

        params = _build_revoke_payload(
            namespace,
            resource,
            relation,
            subject_id,
            subject_set,
        )
        response = await self._request(
            "DELETE", self.keto_write("/admin/relation-tuples").with_query(params)
        )

        if response.status == status.HTTP_400_BAD_REQUEST:
            self._logger.warning("Failed to revoke for some reason")
            response.release()
            return

        await response.release()
        await self._invalidate_resource(namespace, resource)

    async def grant(
        self,
        namespace: str,
        resource: str,
        relation: str,
        *,
        subject_id: str | None = None,
        subject_set: SubjectSet | None = None,
    ) -> None:
        """Upsert a Keto relation tuple.

        Idempotent at the spec level — Keto returns 201 on first write
        and treats repeated grants as no-ops. On success, all cached
        :meth:`check_permission` results for the affected
        `(namespace, object)` are invalidated.

        Args:
            namespace: Resource type, e.g. `"Project"`.
            resource: Resource id.
            relation: Relation name being asserted, e.g. `"owners"`.
            subject_id: Direct identity-id subject. Pass exactly one of
                `subject_id` or `subject_set`.
            subject_set: Subject-set reference (e.g. `Role:admin#member`)
                — typically built via :func:`role_subject_set`. Pass
                exactly one of `subject_id` or `subject_set`.

        Raises:
            ValueError: If neither or both of `subject_id` /
                `subject_set` are provided.
        """

        def _build_grant_payload(
            namespace: str,
            resource: str,
            relation: str,
            subject_id: str | None,
            subject_set: SubjectSet | None,
        ) -> dict[str, str | SubjectSet]:
            if (subject_id is None) == (subject_set is None):
                msg = "Pass exactly one of subject_id or subject_set"
                raise ValueError(msg)

            payload: dict[str, str | SubjectSet] = {
                "namespace": namespace,
                "object": resource,
                "relation": relation,
            }
            if subject_id is not None:
                payload["subject_id"] = subject_id
            elif subject_set is not None:
                payload["subject_set"] = subject_set
            return payload

        payload = _build_grant_payload(
            namespace,
            resource,
            relation,
            subject_id,
            subject_set,
        )
        response = await self._request(
            "PUT",
            self.keto_write("/admin/relation-tuples"),
            json=payload,
        )

        if response.status == status.HTTP_400_BAD_REQUEST:
            self._logger.warning("Failed to grant for some reason")
            response.release()
            return

        response.release()
        await self._invalidate_resource(namespace, resource)
