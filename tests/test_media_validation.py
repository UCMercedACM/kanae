# ruff: noqa: S101

import pytest
from fastapi import HTTPException
from hypothesis import (
    HealthCheck,
    given,
    settings,
    strategies as st,
)

from core import ALLOWED_IMAGE_TYPES, ALLOWED_VIDEO_TYPES
from routes.projects import (
    _MAX_IMAGE_SIZE,
    _MAX_VIDEO_SIZE,
    _validate_media,
)
from utils.errors import BadRequestError

_ALLOWED_TYPES: frozenset[str] = ALLOWED_IMAGE_TYPES | ALLOWED_VIDEO_TYPES
_DISALLOWED_FIXED: tuple[str, ...] = (
    "application/pdf",
    "text/plain",
    "image/bmp",
    "image/tiff",
    "video/avi",
    "video/x-msvideo",
    "audio/mpeg",
    "application/octet-stream",
    "",
)


# ──────────────────────────────────────────────────────────────────
# Boundary tests for size limits, explicit and per-kind.
#
# Size limits are exact thresholds, not a search space — hypothesis adds no
# signal here, but the boundaries themselves are exactly where bugs live
# (off-by-one comparisons, signed/unsigned overflow, etc.).
# ──────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("content_type", sorted(ALLOWED_IMAGE_TYPES))
@pytest.mark.parametrize(
    "size",
    [
        1,
        _MAX_IMAGE_SIZE - 1,
        _MAX_IMAGE_SIZE,
    ],
)
def test_image_size_within_limit_passes(content_type: str, size: int) -> None:
    # No exception, no return value.
    assert _validate_media(content_type, size) is None


@pytest.mark.parametrize("content_type", sorted(ALLOWED_IMAGE_TYPES))
@pytest.mark.parametrize(
    "size",
    [
        _MAX_IMAGE_SIZE + 1,
        _MAX_IMAGE_SIZE * 2,
    ],
)
def test_image_size_over_limit_raises_413(content_type: str, size: int) -> None:
    with pytest.raises(HTTPException) as exc_info:
        _validate_media(content_type, size)
    assert exc_info.value.status_code == 413


@pytest.mark.parametrize("content_type", sorted(ALLOWED_VIDEO_TYPES))
@pytest.mark.parametrize(
    "size",
    [
        1,
        _MAX_VIDEO_SIZE - 1,
        _MAX_VIDEO_SIZE,
    ],
)
def test_video_size_within_limit_passes(content_type: str, size: int) -> None:
    assert _validate_media(content_type, size) is None


@pytest.mark.parametrize("content_type", sorted(ALLOWED_VIDEO_TYPES))
@pytest.mark.parametrize(
    "size",
    [
        _MAX_VIDEO_SIZE + 1,
        _MAX_VIDEO_SIZE * 2,
    ],
)
def test_video_size_over_limit_raises_413(content_type: str, size: int) -> None:
    with pytest.raises(HTTPException) as exc_info:
        _validate_media(content_type, size)
    assert exc_info.value.status_code == 413


@pytest.mark.parametrize(
    "content_type", sorted(ALLOWED_IMAGE_TYPES | ALLOWED_VIDEO_TYPES)
)
@pytest.mark.parametrize("size", [0, -1, -(2**31)])
def test_non_positive_size_raises_bad_request(content_type: str, size: int) -> None:
    with pytest.raises(BadRequestError):
        _validate_media(content_type, size)


@pytest.mark.parametrize("content_type", _DISALLOWED_FIXED)
def test_disallowed_content_type_raises_415(content_type: str) -> None:
    with pytest.raises(HTTPException) as exc_info:
        _validate_media(content_type, 1024)
    assert exc_info.value.status_code == 415


# ──────────────────────────────────────────────────────────────────
# Property tests — fuzz the validator with arbitrary inputs.
#
# These exist to catch "validator crashes on input X" bugs that the
# enumerated tests above can't reach: arbitrary unicode content types,
# extreme size values, off-domain combinations. The validator must always
# end in one of three outcomes — return None, raise HTTPException, or
# raise BadRequestError — and never anything else.
# ──────────────────────────────────────────────────────────────────


@given(
    content_type=st.text(min_size=0, max_size=200),
    size=st.integers(min_value=-(2**62), max_value=2**62),
)
@settings(
    max_examples=200,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)
def test_validator_terminates_in_a_known_outcome(content_type: str, size: int) -> None:
    try:
        _validate_media(content_type, size)
    except HTTPException:
        # Any 4xx-shaped rejection is fine. BadRequestError is a subclass
        # of HTTPException via BaseHTTPException, so it's already covered.
        return
    # Only valid (content_type, size) combinations should fall through.
    assert content_type in _ALLOWED_TYPES
    cap = _MAX_IMAGE_SIZE if content_type in ALLOWED_IMAGE_TYPES else _MAX_VIDEO_SIZE
    assert 0 < size <= cap


@given(
    content_type=st.text(min_size=1, max_size=200).filter(
        lambda value: value not in _ALLOWED_TYPES
    ),
    size=st.integers(min_value=1, max_value=_MAX_IMAGE_SIZE),
)
@settings(
    max_examples=100,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.filter_too_much],
)
def test_arbitrary_content_type_outside_allowlist_rejected_415(
    content_type: str, size: int
) -> None:
    # Anything not in the allow-list — including the empty string, unicode
    # control chars, near-misses like "image/png " with a trailing space —
    # must be 415; we should never silently accept it.
    with pytest.raises(HTTPException) as exc_info:
        _validate_media(content_type, size)
    assert exc_info.value.status_code == 415


@given(
    content_type=st.sampled_from(sorted(ALLOWED_IMAGE_TYPES)),
    size=st.integers(min_value=_MAX_IMAGE_SIZE + 1, max_value=_MAX_VIDEO_SIZE * 2),
)
@settings(
    max_examples=50,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)
def test_image_oversize_always_413(content_type: str, size: int) -> None:
    with pytest.raises(HTTPException) as exc_info:
        _validate_media(content_type, size)
    assert exc_info.value.status_code == 413


@given(
    content_type=st.sampled_from(sorted(ALLOWED_VIDEO_TYPES)),
    size=st.integers(min_value=_MAX_VIDEO_SIZE + 1, max_value=_MAX_VIDEO_SIZE * 4),
)
@settings(
    max_examples=50,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)
def test_video_oversize_always_413(content_type: str, size: int) -> None:
    with pytest.raises(HTTPException) as exc_info:
        _validate_media(content_type, size)
    assert exc_info.value.status_code == 413
