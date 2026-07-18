"""Minimal OpenAI-compatible client for a deployed FreeSolo adapter."""

from __future__ import annotations

import asyncio
import json
import math
import os
from dataclasses import dataclass, field
from typing import Any, Mapping
from urllib.parse import urlsplit

import httpx

from .canonical import MODEL_ACTION_CODES
from .models import SCHEMA_VERSION


SYSTEM_PROMPT = """You are Picture Perfect's low-latency photo-coaching engine.
The user supplies precomputed image statistics, not pixels. Never infer objects,
identity, pose, mood, or scene details that the statistics do not establish.

Return exactly one JSON object, with no markdown or prose, using this shape:
{"schemaVersion":1,"actionCodes":["CODE_A","CODE_B","CODE_C"]}

Return exactly the canonical first 3 action codes in importance order. The
backend owns any fourth action. Do not add keys, scores, parameters,
explanations, observations, markdown, or other prose.

Allowed codes: LEVEL_HORIZON, PLACE_SUBJECT_THIRDS, BRIGHTEN_EXPOSURE,
REDUCE_EXPOSURE, RECOVER_HIGHLIGHTS, OPEN_SHADOWS, ADD_TONAL_SEPARATION,
SOFTEN_CONTRAST, LOCK_FOCUS, REDUCE_NOISE, NEUTRALIZE_COLOR_CAST,
STRENGTHEN_COLOR, TAME_SATURATION, KEEP_LEVEL, PROTECT_HIGHLIGHTS,
and no other codes."""


class FreeSoloError(RuntimeError):
    """The optional model call failed; callers should use canonical fallback."""


@dataclass(frozen=True)
class FreeSoloSettings:
    base_url: str = ""
    api_key: str = field(default="", repr=False)
    model: str = ""
    preview_timeout_seconds: float = 1.2
    capture_timeout_seconds: float = 5.0
    max_tokens: int = 128
    enable_preview: bool = False

    def __post_init__(self) -> None:
        configured_values = (
            bool(self.base_url.strip()),
            bool(self.api_key.strip()),
            bool(self.model.strip()),
        )
        if any(configured_values) and not all(configured_values):
            raise ValueError(
                "FREESOLO_OPENAI_BASE_URL, FREESOLO_API_KEY, and FREESOLO_MODEL "
                "must be configured together"
            )
        if all(configured_values):
            _validate_base_url(self.base_url)
            _validate_visible_ascii(
                self.api_key,
                variable_name="FREESOLO_API_KEY",
                maximum_length=4_096,
            )
            _validate_visible_ascii(
                self.model,
                variable_name="FREESOLO_MODEL",
                maximum_length=256,
            )
        _validate_positive_float(
            self.preview_timeout_seconds,
            variable_name="FREESOLO_PREVIEW_TIMEOUT_SECONDS",
        )
        _validate_positive_float(
            self.capture_timeout_seconds,
            variable_name="FREESOLO_CAPTURE_TIMEOUT_SECONDS",
        )
        if not 1 <= self.max_tokens <= 2_048:
            raise ValueError("FREESOLO_MAX_TOKENS must be an integer within 1..2048")

    @property
    def configured(self) -> bool:
        return bool(self.base_url.strip() and self.api_key.strip() and self.model.strip())

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> "FreeSoloSettings":
        values = os.environ if environ is None else environ
        return cls(
            base_url=values.get("FREESOLO_OPENAI_BASE_URL", "").strip(),
            api_key=values.get("FREESOLO_API_KEY", "").strip(),
            model=values.get("FREESOLO_MODEL", "").strip(),
            enable_preview=_strict_bool(
                values.get("FREESOLO_ENABLE_PREVIEW"),
                default=False,
                variable_name="FREESOLO_ENABLE_PREVIEW",
            ),
            preview_timeout_seconds=_positive_float(
                values.get("FREESOLO_PREVIEW_TIMEOUT_SECONDS"),
                1.2,
                variable_name="FREESOLO_PREVIEW_TIMEOUT_SECONDS",
            ),
            capture_timeout_seconds=_positive_float(
                values.get("FREESOLO_CAPTURE_TIMEOUT_SECONDS"),
                5.0,
                variable_name="FREESOLO_CAPTURE_TIMEOUT_SECONDS",
            ),
            max_tokens=_positive_int(
                values.get("FREESOLO_MAX_TOKENS"),
                128,
                variable_name="FREESOLO_MAX_TOKENS",
            ),
        )


def _strict_bool(raw: str | None, *, default: bool, variable_name: str) -> bool:
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise ValueError(f'{variable_name} must be exactly "true" or "false"')


def _positive_float(
    raw: str | None,
    default: float,
    *,
    variable_name: str,
) -> float:
    if raw is None:
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(
            f"{variable_name} must be a number greater than 0 and at most 30"
        ) from exc
    _validate_positive_float(value, variable_name=variable_name)
    return value


def _positive_int(
    raw: str | None,
    default: int,
    *,
    variable_name: str,
) -> int:
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(
            f"{variable_name} must be an integer within 1..2048"
        ) from exc
    if not 1 <= value <= 2_048:
        raise ValueError(f"{variable_name} must be an integer within 1..2048")
    return value


def _validate_positive_float(value: float, *, variable_name: str) -> None:
    if not math.isfinite(value) or not 0.0 < value <= 30.0:
        raise ValueError(
            f"{variable_name} must be a finite number greater than 0 and at most 30"
        )


def _validate_visible_ascii(
    value: str,
    *,
    variable_name: str,
    maximum_length: int,
) -> None:
    if len(value) > maximum_length or any(not 0x21 <= ord(char) <= 0x7E for char in value):
        raise ValueError(
            f"{variable_name} must contain only visible ASCII characters and be "
            f"at most {maximum_length} characters"
        )


def _validate_base_url(value: str) -> None:
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError("FREESOLO_OPENAI_BASE_URL contains an invalid port") from exc
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or (port is not None and not 1 <= port <= 65_535)
    ):
        raise ValueError(
            "FREESOLO_OPENAI_BASE_URL must be an HTTPS URL without credentials, "
            "a query, or a fragment"
        )


PHOTO_COACH_JSON_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "schemaVersion": {"type": "integer", "enum": [SCHEMA_VERSION]},
        "actionCodes": {
            "type": "array",
            "minItems": 3,
            "maxItems": 3,
            "uniqueItems": True,
            "items": {"type": "string", "enum": sorted(MODEL_ACTION_CODES)},
        },
    },
    "required": ["schemaVersion", "actionCodes"],
}

# FreeSolo's deployed OpenAI-compatible endpoint accepts JSON mode but rejects
# OpenAI's nested ``json_schema`` response format.  The schema above remains the
# backend's documented contract; canonical validation is the correctness gate.
JSON_OBJECT_RESPONSE_FORMAT: dict[str, str] = {"type": "json_object"}


class FreeSoloClient:
    def __init__(
        self,
        settings: FreeSoloSettings,
        *,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self.settings = settings
        self._owns_client = http_client is None
        self._client = http_client or httpx.AsyncClient()

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def propose(
        self,
        payload: Mapping[str, Any],
        *,
        timeout_seconds: float,
    ) -> str:
        if not self.settings.configured:
            raise FreeSoloError("FreeSolo serving is not configured")
        url = f'{self.settings.base_url.rstrip("/")}/chat/completions'
        request_body = {
            "model": self.settings.model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": json.dumps(
                        payload,
                        sort_keys=True,
                        separators=(",", ":"),
                        ensure_ascii=True,
                    ),
                },
            ],
            "temperature": 0.0,
            "max_tokens": self.settings.max_tokens,
            "response_format": JSON_OBJECT_RESPONSE_FORMAT,
        }
        try:
            # HTTPX timeouts apply to individual network phases. The outer
            # deadline bounds the complete paid inference operation.
            async with asyncio.timeout(timeout_seconds):
                response = await self._client.post(
                    url,
                    json=request_body,
                    headers={
                        "Authorization": f"Bearer {self.settings.api_key}",
                        "Content-Type": "application/json",
                    },
                    timeout=httpx.Timeout(timeout_seconds),
                )
                response.raise_for_status()
                body = response.json()
                content = body["choices"][0]["message"]["content"]
        except (
            TimeoutError,
            httpx.HTTPError,
            KeyError,
            IndexError,
            TypeError,
            ValueError,
        ) as exc:
            raise FreeSoloError(f"FreeSolo inference failed: {type(exc).__name__}") from exc
        if not isinstance(content, str) or not content.strip():
            raise FreeSoloError("FreeSolo inference returned no text content")
        return content.strip()
