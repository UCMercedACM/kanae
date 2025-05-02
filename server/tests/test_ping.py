from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from conftest import KanaeTestClient


@pytest.mark.asyncio()
async def test_ping(app: KanaeTestClient):
    response = await app.client.get("/docs")
    assert response.status_code == 200
