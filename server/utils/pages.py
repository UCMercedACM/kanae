from __future__ import annotations

from typing import Annotated, Any, Generic, Optional, Sequence, TypeVar

import asyncpg
from fastapi import Query
from fastapi_pagination.api import apply_items_transformer, create_page
from fastapi_pagination.bases import AbstractPage, AbstractParams, RawParams
from fastapi_pagination.types import AdditionalData, AsyncItemsTransformer
from fastapi_pagination.utils import verify_params

T = TypeVar("T")


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


async def paginate(
    pool: asyncpg.Pool,
    query: str,
    *args: Any,
    transformer: Optional[AsyncItemsTransformer] = None,
    params: Optional[KanaeParams] = None,
    additional_data: Optional[AdditionalData] = None,
) -> Any:
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


class KanaeParams(AbstractParams):
    page: Annotated[int, Query(default=1, ge=1)]
    size: Annotated[int, Query(default=50, ge=1, le=100)]

    def __init__(self, page: int = 1, size: int = 50):
        self.page = page
        self.size = size

    def to_raw_params(self) -> RawParams:
        return RawParams(
            limit=self.size,
            offset=(self.page - 1) * self.size,
            include_total=True,  # skip total calculation
        )


class KanaePages(AbstractPage[T], Generic[T]):
    data: list[T]
    total: int

    __params_type__ = KanaeParams

    @classmethod
    def create(  # type: ignore
        cls,
        items: Sequence[T],
        params: KanaeParams,
        *,
        total: Optional[int] = None,
        **kwargs: Any,
    ) -> KanaePages[T]:
        assert total is not None, "total must be provided"

        return cls(
            data=items,
            total=total,
        )
