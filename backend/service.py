"""Orchestrate canonical analysis, optional FreeSolo inference, and rendering."""

from __future__ import annotations

import logging
from dataclasses import dataclass

from .canonical import expected_plan, payload_for_measurements, validate_or_fallback
from .freesolo_client import FreeSoloClient, FreeSoloError, FreeSoloSettings
from .models import AnalysisMode, AnalyzePhotoRequest, PhotoAnalysis
from .renderer import render_plan


logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AnalysisResult:
    analysis: PhotoAnalysis
    source: str
    model_revision: str | None
    model_attempted: bool
    model_responded: bool
    validation_reason: str


class PhotoAnalysisService:
    def __init__(
        self,
        *,
        freesolo_client: FreeSoloClient | None = None,
        settings: FreeSoloSettings | None = None,
    ) -> None:
        self.settings = settings or FreeSoloSettings()
        self.freesolo_client = freesolo_client

    @classmethod
    def from_env(cls) -> "PhotoAnalysisService":
        settings = FreeSoloSettings.from_env()
        client = FreeSoloClient(settings) if settings.configured else None
        return cls(freesolo_client=client, settings=settings)

    async def close(self) -> None:
        if self.freesolo_client is not None:
            await self.freesolo_client.close()

    async def analyze(self, request: AnalyzePhotoRequest) -> AnalysisResult:
        payload = payload_for_measurements(
            request.measurements,
            mode=request.mode.value,
            intent=request.intent.value,
        )
        expected = expected_plan(payload)
        candidate: str | None = None
        model_error: str | None = None
        remote_enabled = (
            request.mode == AnalysisMode.CAPTURE or self.settings.enable_preview
        )
        model_attempted = self.freesolo_client is not None and remote_enabled
        if model_attempted:
            timeout = (
                self.settings.preview_timeout_seconds
                if request.mode == AnalysisMode.PREVIEW
                else self.settings.capture_timeout_seconds
            )
            try:
                candidate = await self.freesolo_client.propose(
                    payload,
                    timeout_seconds=timeout,
                )
            except FreeSoloError as exc:
                model_error = str(exc)
                logger.info("Using canonical fallback: %s", model_error)

        outcome = validate_or_fallback(candidate, expected)
        source = "freesolo-validated" if outcome.model_accepted else "deterministic-fallback"
        seed = request.session_id or request.request_id
        analysis = render_plan(
            outcome.plan,
            seed=seed,
            advice_epoch=request.advice_epoch,
        )
        return AnalysisResult(
            analysis=analysis,
            source=source,
            # Only attribute advice to the remote revision when its exact ordered
            # plan passed validation. Preview, timeout, and mismatch fallbacks are
            # wholly deterministic and must not carry a misleading model header.
            model_revision=(
                self.settings.model if outcome.model_accepted else None
            ),
            model_attempted=model_attempted,
            model_responded=candidate is not None,
            validation_reason=model_error or outcome.reason,
        )
