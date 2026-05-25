from collections.abc import Sequence
from typing import Annotated, Any, Optional, Self

import asyncpg
from fastapi import Query
from fastapi_pagination.api import apply_items_transformer, create_page
from fastapi_pagination.bases import AbstractPage, AbstractParams, RawParams
from fastapi_pagination.types import AsyncItemsTransformer
from fastapi_pagination.utils import verify_params


def create_paginate_query_from_text(query: str, params: AbstractParams) -> str:
    raw_params = params.to_raw_params().as_limit_offset()

    suffix = ""
    if raw_params.limit is not None:
        suffix += f" LIMIT {raw_params.limit}"
    if raw_params.offset is not None:
        suffix += f" OFFSET {raw_params.offset}"

    return f"{query} {suffix}".strip()


def create_count_query_from_text(query: str) -> str:
    return f"SELECT count(*) FROM ({query}) AS __count_query__"  # noqa: S608


# 2**31 - 1 equals to 2,147,483,647
# This also assumes two's complement, thus this would make that the max value for a signed 32-bit int
# We could use 2**63 - 1 (signed 64-bit max), but since we use INT
# (which is 32-bit, compared to BIGINT, which is 64-bit), we will safely assume the 32-bit max limit instead
# Also, the future import was causing issues with ForwardRefs for Pydantic
class KanaeParams(AbstractParams):
    def __init__(
        self,
        page: Annotated[int, Query(ge=1, le=2**31 - 1)] = 1,
        size: Annotated[int, Query(ge=1, le=100)] = 50,
    ) -> None:
        self.page = page
        self.size = size

    def to_raw_params(self) -> RawParams:
        return RawParams(
            limit=self.size,
            offset=(self.page - 1) * self.size,
            include_total=True,  # skip total calculation
        )


class KanaePages[T](AbstractPage[T]):
    data: list[T]
    total: int

    __params_type__ = KanaeParams

    @classmethod
    def create(  # ty: ignore[invalid-method-override]
        cls,
        items: Sequence[T],
        params: KanaeParams,
        *,
        total: Optional[int] = None,
        **kwargs: object,
    ) -> Self:
        if total is None:
            msg = "total must be provided"
            raise ValueError(msg)

        return cls(
            data=list(items),
            total=total,
        )


async def paginate(
    pool: asyncpg.Pool,
    query: str,
    *args: object,
    transformer: Optional[AsyncItemsTransformer] = None,
    params: Optional[KanaeParams] = None,
    additional_data: Optional[dict[str, Any]] = None,
) -> AbstractPage[Any]:
    params, raw_params = verify_params(params, "limit-offset")

    if raw_params.include_total:
        total = await pool.fetchval(
            create_count_query_from_text(query),
            *args,
        )
    else:
        total = None

    items = await pool.fetch(create_paginate_query_from_text(query, params), *args)
    items = [{**r} for r in items]
    t_items = await apply_items_transformer(items, transformer, async_=True)

    return create_page(
        t_items,
        total=total,
        params=params,
        **(additional_data or {}),
    )
