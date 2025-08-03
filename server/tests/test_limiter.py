import hiro
import pytest
from httpx import ASGITransport, AsyncClient
from starlette.requests import Request
from starlette.responses import PlainTextResponse, Response
from utils.limiter import get_ipaddr
from yarl import URL


@pytest.mark.asyncio
async def test_single_decorator(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr)

    @app.get("/t1")
    @limiter.limit("5/minute")
    async def t1(request: Request):
        return PlainTextResponse("test")

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        for i in range(0, 10):
            response = await client.get("/t1")

            assert response.status_code == 200 if i < 5 else 429


@pytest.mark.asyncio
async def test_single_decorator_with_headers(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr, headers_enabled=True)

    @app.get("/t1")
    @limiter.limit("5/minute")
    async def t1(request: Request):
        return PlainTextResponse("test")

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        for i in range(0, 10):
            response = await client.get("/t1")

            assert response.status_code == 200 if i < 5 else 429
            assert (
                response.headers.get("X-RateLimit-Limit") is not None if i < 5 else True
            )
            assert response.headers.get("Retry-After") is not None if i < 5 else True


@pytest.mark.asyncio
async def test_single_decorator_not_response(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr)

    @app.get("/t1")
    @limiter.limit("5/minute")
    async def t1(request: Request, response: Response):
        return {"key": "value"}

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        for i in range(0, 10):
            response = await client.get("/t1")

            assert response.status_code == 200 if i < 5 else 429


@pytest.mark.asyncio
async def test_single_decorator_not_response_with_headers(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr, headers_enabled=True)

    @app.get("/t1")
    @limiter.limit("5/minute")
    async def t1(request: Request, response: Response):
        return {"key": "value"}

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        for i in range(0, 10):
            response = await client.get("/t1")

            assert response.status_code == 200 if i < 5 else 429
            assert (
                response.headers.get("X-RateLimit-Limit") is not None if i < 5 else True
            )
            assert response.headers.get("Retry-After") is not None if i < 5 else True


@pytest.mark.asyncio
async def test_multiple_decorators(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr)

    @app.get("/t1")
    @limiter.limit(
        "100 per minute", lambda: "test"
    )  # effectively becomes a limit for all users
    @limiter.limit("50/minute")  # per ip as per default key_func
    async def t1(request: Request):
        return PlainTextResponse("test")

    with hiro.Timeline() as timeline:
        timeline.freeze()

        transport = ASGITransport(app=app)
        async with AsyncClient(
            transport=transport,
            base_url=str(URL.build(scheme="http", host="testserver")),
        ) as cli:
            for i in range(0, 100):
                response = await cli.get(
                    "/t1", headers={"X_FORWARDED_FOR": "127.0.0.2"}
                )
                assert response.status_code == 200 if i < 50 else 429

            for i in range(50):
                resp = await cli.get("/t1")
                assert resp.status_code == 200
            re = await cli.get("/t1")
            assert re.status_code == 429

            rep = await cli.get("/t1", headers={"X_FORWARDED_FOR": "127.0.0.3"})
            assert rep.status_code == 429


@pytest.mark.asyncio
async def test_multiple_decorators_not_response(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr)

    @app.get("/t1")
    @limiter.limit(
        "100 per minute", lambda: "test"
    )  # effectively becomes a limit for all users
    @limiter.limit("50/minute")  # per ip as per default key_func
    async def t1(request: Request, response: Response):
        return {"key": "value"}

    with hiro.Timeline() as timeline:
        timeline.freeze()

        transport = ASGITransport(app=app)
        async with AsyncClient(
            transport=transport,
            base_url=str(URL.build(scheme="http", host="testserver")),
        ) as cli:
            for i in range(0, 100):
                response = await cli.get(
                    "/t1", headers={"X_FORWARDED_FOR": "127.0.0.2"}
                )
                assert response.status_code == 200 if i < 50 else 429
            for i in range(50):
                assert (await cli.get("/t1")).status_code == 200
            assert (await cli.get("/t1")).status_code == 429
            assert (
                await cli.get("/t1", headers={"X_FORWARDED_FOR": "127.0.0.3"})
            ).status_code == 429


@pytest.mark.asyncio
async def test_multiple_decorators_not_response_with_headers(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr, headers_enabled=True)

    @app.get("/t1")
    @limiter.limit(
        "100 per minute", lambda: "test"
    )  # effectively becomes a limit for all users
    @limiter.limit("50/minute")  # per ip as per default key_func
    async def t1(request: Request, response: Response):
        return {"key": "value"}

    with hiro.Timeline() as timeline:
        timeline.freeze()

        transport = ASGITransport(app=app)
        async with AsyncClient(
            transport=transport,
            base_url=str(URL.build(scheme="http", host="testserver")),
        ) as cli:
            for i in range(0, 100):
                response = await cli.get(
                    "/t1", headers={"X_FORWARDED_FOR": "127.0.0.2"}
                )
                assert response.status_code == 200 if i < 50 else 429

            for i in range(50):
                assert (await cli.get("/t1")).status_code == 200
            assert (await cli.get("/t1")).status_code == 429

            resp = await cli.get("/t1", headers={"X_FORWARDED_FOR": "127.0.0.3"})
            assert resp.status_code == 429


@pytest.mark.asyncio
async def test_endpoint_missing_request_param(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr)
    with pytest.raises(ValueError) as exc_info:

        @app.get("/t3")
        @limiter.limit("5/minute")
        async def t3():
            return PlainTextResponse("test")

    assert exc_info.match(r"^Missing or invalid `request` argument specified on .*")


@pytest.mark.asyncio
async def test_endpoint_request_param_invalid(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr)

    with pytest.raises(ValueError) as exc_info:

        @app.get("/t4")
        @limiter.limit("5/minute")
        async def t4(req: str):
            return PlainTextResponse("test")

    assert exc_info.match(r"^Missing or invalid `request` argument specified on .*")


@pytest.mark.asyncio
async def test_dynamic_limit_provider_depending_on_key(build_fastapi_app):
    def custom_key_func(request: Request):
        if request.headers.get("TOKEN") == "secret":
            return "admin"
        return "user"

    def dynamic_limit_provider(key: str):
        if key == "admin":
            return "10/minute"
        return "5/minute"

    app, limiter = build_fastapi_app(key_func=custom_key_func)

    @app.get("/t1")
    @limiter.limit(dynamic_limit_provider)
    async def t1(request: Request, response: Response):
        return {"key": "value"}

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        for i in range(0, 10):
            response = await client.get("/t1")

            assert response.status_code == 200 if i < 5 else 429
        for i in range(0, 20):
            response = await client.get("/t1", headers={"TOKEN": "secret"})

            assert response.status_code == 200 if i < 10 else 429


@pytest.mark.asyncio
async def test_disabled_limiter(build_fastapi_app):
    """
    Check that the limiter does nothing if disabled (both sync and async)
    """
    app, limiter = build_fastapi_app(key_func=get_ipaddr, enabled=False)

    @app.get("/t1")
    @limiter.limit("5/minute")
    async def t1(request: Request):
        return PlainTextResponse("test")

    @app.get("/t3")
    async def t3(request: Request):
        return PlainTextResponse("also a test")

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        for _ in range(0, 10):
            response = await client.get("/t1")

            assert response.status_code == 200
        for _ in range(0, 10):
            response = await client.get("/t3")

            assert response.status_code == 200


@pytest.mark.asyncio
async def test_cost(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr)

    @app.get("/t1")
    @limiter.limit("50/minute", cost=10)
    async def t1(request: Request):
        return PlainTextResponse("test")

    @app.get("/t2")
    @limiter.limit("50/minute", cost=15)
    async def t2(request: Request):
        return PlainTextResponse("test")

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        for i in range(0, 10):
            response = await client.get("/t1")
            assert response.status_code == 200 if i < 5 else 429
            response = await client.get("/t2")
            assert response.status_code == 200 if i < 3 else 429


# @pytest.mark.skip("Weird edge-case, will not be used")
@pytest.mark.asyncio
async def test_callable_cost(build_fastapi_app):
    app, limiter = build_fastapi_app(key_func=get_ipaddr)

    @app.get("/t1")
    @limiter.limit("50/minute", cost=lambda request: int(request.headers["foo"]))
    async def t1(request: Request):
        return PlainTextResponse("test")

    @app.get("/t2")
    @limiter.limit("50/minute", cost=lambda request: int(request.headers["foo"]) * 1.5)
    async def t2(request: Request):
        return PlainTextResponse("test")

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        for i in range(0, 10):
            response = await client.get("/t1", headers={"foo": "10"})

            assert response.status_code == 200 if i < 5 else 429
        for i in range(0, 10):
            response = await client.get("/t2", headers={"foo": "5"})

            assert response.status_code == 200 if i < 6 else 429


@pytest.mark.parametrize(
    "key_style",
    ["url", "endpoint"],
)
@pytest.mark.asyncio
async def test_key_style(build_fastapi_app, key_style):
    app, limiter = build_fastapi_app(key_func=lambda: "mock", key_style=key_style)

    @app.get("/t1/{my_param}")
    @limiter.limit("1/minute")
    async def t1_func(my_param: str, request: Request):
        return PlainTextResponse("test")

    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url=str(URL.build(scheme="http", host="testserver"))
    ) as client:
        await client.get("/t1/param_one")
        second_call = await client.get("/t1/param_two")

        # with the "url" key_style, since the `my_param` value changed, the storage key is different
        # meaning it should not raise any RateLimitExceeded error.
        if key_style == "url":
            assert second_call.status_code == 200
            assert (
                await limiter._storage.get("LIMITER/mock//t1/param_one/1/1/minute") == 1
            )
            assert (
                await limiter._storage.get("LIMITER/mock//t1/param_two/1/1/minute") == 1
            )
        # However, with the `endpoint` key_style, it will use the function name (e.g: "t1_func")
        # meaning it will raise a RateLimitExceeded error, because no matter the parameter value
        # it will share the limitations.
        elif key_style == "endpoint":
            assert second_call.status_code == 429
            # check that we counted 2 requests, even though we had a different value for "my_param"
            assert (
                await limiter._storage.get(
                    f"LIMITER/mock/{t1_func.__module__}.{t1_func.__name__}/1/1/minute"
                )
                == 2
            )
