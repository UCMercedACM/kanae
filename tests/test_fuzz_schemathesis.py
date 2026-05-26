# ruff: noqa: S101

from typing import Any

import pytest
import schemathesis
from conftest import FakeOryClient, KanaeTestClient
from hypothesis import HealthCheck, settings

from core import Kanae
from utils.checks import Role

pytestmark = pytest.mark.asyncio(loop_scope="session")


@pytest.fixture(scope="session")
def api_schema(kanae: Kanae) -> schemathesis.BaseSchema:
    return schemathesis.openapi.from_dict(kanae.openapi())


schema = schemathesis.pytest.from_fixture("api_schema")


@schema.parametrize()
@settings(
    max_examples=30,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
async def test_no_5xx_responses(
    case: schemathesis.Case,
    client: KanaeTestClient,
    fake_ory: FakeOryClient,
) -> None:
    fake_ory.login_as(Role.ADMIN)

    raw_kwargs: dict[str, Any] = case.as_transport_kwargs(base_url="")
    httpx_keys = {
        "method",
        "url",
        "params",
        "headers",
        "json",
        "data",
        "content",
        "files",
    }
    kwargs = {k: v for k, v in raw_kwargs.items() if k in httpx_keys and v is not None}

    if isinstance(kwargs.get("data"), (bytes, bytearray, str)):
        kwargs["content"] = kwargs.pop("data")

    response = await client.client.request(**kwargs)
    assert response.status_code < 500, (
        f"{kwargs.get('method')} {kwargs.get('url')!r} returned "
        f"{response.status_code}: {response.text[:200]}"
    )
