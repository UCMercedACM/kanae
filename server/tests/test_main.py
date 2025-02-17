import pytest_asyncio
from conftest import KanaeTestClient


@pytest_asyncio.fixture
async def test_read_main(server: KanaeTestClient):
    response = await server.client.get("/docs")
    assert response.status_code == 200
