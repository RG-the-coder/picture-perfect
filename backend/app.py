"""FastAPI entry point for Picture Perfect's structured-measurement backend."""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

from fastapi import FastAPI, Response
from fastapi.middleware.cors import CORSMiddleware

from .models import SCHEMA_VERSION, AnalyzePhotoRequest, PhotoAnalysis
from .service import PhotoAnalysisService


SERVICE_ID = "picture-perfect-analysis"
API_VERSION = 1
STARTUP_MODEL_STATUSES = frozenset(
    {"not-probed", "unavailable", "responded-rejected", "validated"}
)


def _allowed_origins(raw: str) -> tuple[str, ...]:
    origins: list[str] = []
    for candidate in raw.split(","):
        origin = candidate.strip().rstrip("/")
        if not origin:
            continue
        parsed = urlsplit(origin)
        try:
            port = parsed.port
        except ValueError as exc:
            raise ValueError(
                "PICTUREPERFECT_ALLOWED_ORIGINS contains an invalid port"
            ) from exc
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(
                "PICTUREPERFECT_ALLOWED_ORIGINS must contain only HTTP(S) origins"
            )
        normalized = f"{parsed.scheme}://{parsed.hostname}"
        if port is not None:
            normalized = f"{normalized}:{port}"
        if normalized not in origins:
            origins.append(normalized)
    return tuple(origins)


def create_app(
    service: PhotoAnalysisService | None = None,
    *,
    allowed_origins: tuple[str, ...] | None = None,
) -> FastAPI:
    analysis_service = service or PhotoAnalysisService.from_env()

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        yield
        await analysis_service.close()

    application = FastAPI(
        title="Picture Perfect Analysis API",
        version="1.0.0",
        lifespan=lifespan,
    )
    origins = (
        _allowed_origins(",".join(allowed_origins))
        if allowed_origins is not None
        else _allowed_origins(os.environ.get("PICTUREPERFECT_ALLOWED_ORIGINS", ""))
    )
    if origins:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=list(origins),
            allow_credentials=False,
            allow_methods=["POST", "OPTIONS"],
            allow_headers=["Content-Type"],
            expose_headers=[
                "X-Request-ID",
                "X-Analysis-Source",
                "X-Model-Revision",
                "X-Model-Attempted",
                "X-Model-Responded",
            ],
        )
    application.state.analysis_service = analysis_service
    application.state.allowed_origins = origins
    startup_model_status = os.environ.get(
        "PICTUREPERFECT_STARTUP_MODEL_STATUS",
        "not-probed",
    )
    if startup_model_status not in STARTUP_MODEL_STATUSES:
        startup_model_status = "not-probed"

    @application.get("/healthz")
    async def health() -> dict[str, object]:
        configured = (
            analysis_service.freesolo_client is not None
            and analysis_service.settings.configured
        )
        return {
            "status": "ok",
            "service": SERVICE_ID,
            "apiVersion": API_VERSION,
            "schemaVersion": SCHEMA_VERSION,
            "inputModality": "structured-measurements",
            "freesoloConfigured": configured,
            "modelRevision": analysis_service.settings.model if configured else None,
            "previewRemoteEnabled": configured
            and analysis_service.settings.enable_preview,
            "allowedOrigins": list(origins),
            "startupModelStatus": startup_model_status,
        }

    @application.post(
        "/v1/photo-analyses",
        response_model=PhotoAnalysis,
        response_model_by_alias=True,
        response_model_exclude_none=True,
    )
    async def analyze_photo(
        request: AnalyzePhotoRequest,
        response: Response,
    ) -> PhotoAnalysis:
        result = await analysis_service.analyze(request)
        response.headers["X-Request-ID"] = request.request_id
        response.headers["X-Analysis-Source"] = result.source
        response.headers["X-Model-Attempted"] = str(result.model_attempted).lower()
        response.headers["X-Model-Responded"] = str(result.model_responded).lower()
        if result.model_revision:
            response.headers["X-Model-Revision"] = result.model_revision
        return result.analysis

    return application


app = create_app()
