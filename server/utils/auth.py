from utils.exceptions import UnauthorizedException

# Both imports must resolve at runtime (NOT under TYPE_CHECKING). FastAPI
# introspects this dependency's signature via `get_type_hints`, including the
# return annotation `KanaeSession`, to figure out what to inject when a route
# declares `session: Annotated[KanaeSession, Depends(use_session)]`. Hiding
# either under TYPE_CHECKING with `from __future__ import annotations` causes
# `get_type_hints` to raise NameError; FastAPI then falls back to treating the
# parameter as a query-string entry and 422s with "missing query.<name>".
from utils.ory import KanaeSession
from utils.request import RouteRequest


async def use_session(request: RouteRequest) -> KanaeSession:
    """Dependency function that obtains the current Kratos session

    Results are cached via `utils.OryClient`, thus this is cheap to utilize.

    Args:
        request (RouteRequest): Request information. This is silently passed along so there is no need to explicitly pass it.

    Returns:
        KanaeSession: The validated session belonging to the caller.

    Raises:
        UnauthorizedException: The cookie is missing, expired, or rejected by Kratos.

    Example:
        >>> async def get_logged_member(
        ...     session: Annotated[KanaeSession, Depends(use_session)],
        ... ): ...
    """
    cookie = request.cookies.get("ory_kratos_session")
    session = await request.app.ory.whoami(cookie)

    if not session:
        msg = "Authentication required"
        raise UnauthorizedException(msg)

    return session
