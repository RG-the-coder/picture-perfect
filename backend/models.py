"""Strict public and internal data contracts for photo analysis."""

from __future__ import annotations

import math
from enum import StrEnum
from typing import Any, Annotated, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
)


SCHEMA_VERSION = 1


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class AnalysisMode(StrEnum):
    PREVIEW = "preview"
    CAPTURE = "capture"


class PhotoIntent(StrEnum):
    AUTO = "auto"
    PORTRAIT = "portrait"
    LANDSCAPE = "landscape"
    PRODUCT = "product"


class CoachingPriority(StrEnum):
    URGENT = "urgent"
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class OverlayType(StrEnum):
    NONE = "none"
    RULE_OF_THIRDS = "ruleOfThirds"
    SUBJECT_GUIDE = "subjectGuide"
    LEVEL = "level"
    EXPOSURE = "exposure"
    FOCUS = "focus"
    COLOR_BALANCE = "colorBalance"


RequestId = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=128,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]*$",
    ),
]


class Measurements(StrictModel):
    width: int = Field(gt=0, le=16_384)
    height: int = Field(gt=0, le=16_384)
    brightness: float = Field(ge=0.0, le=1.0)
    contrast: float = Field(ge=0.0, le=1.0)
    sharpness: float = Field(ge=0.0, le=1.0)
    saturation: float = Field(ge=0.0, le=1.0)
    highlight_clipping: float = Field(
        alias="highlightClipping", ge=0.0, le=1.0
    )
    shadow_clipping: float = Field(alias="shadowClipping", ge=0.0, le=1.0)
    subject_x: float = Field(alias="subjectX", ge=0.0, le=1.0)
    subject_y: float = Field(alias="subjectY", ge=0.0, le=1.0)
    noise: float = Field(default=0.0, ge=0.0, le=1.0)
    color_cast: float = Field(default=0.0, alias="colorCast", ge=0.0, le=1.0)
    horizon_tilt_degrees: float | None = Field(
        default=None,
        alias="horizonTiltDegrees",
        ge=-90.0,
        le=90.0,
    )

    @field_validator("*", mode="before")
    @classmethod
    def reject_boolean_numbers(cls, value: Any) -> Any:
        if isinstance(value, bool):
            raise ValueError("boolean values are not valid measurements")
        return value

    @field_validator(
        "brightness",
        "contrast",
        "sharpness",
        "saturation",
        "highlight_clipping",
        "shadow_clipping",
        "subject_x",
        "subject_y",
        "noise",
        "color_cast",
        "horizon_tilt_degrees",
    )
    @classmethod
    def require_finite(cls, value: float | None) -> float | None:
        if value is not None and not math.isfinite(value):
            raise ValueError("measurement must be finite")
        return value


class AnalyzePhotoRequest(StrictModel):
    schema_version: Literal[SCHEMA_VERSION] = Field(
        default=SCHEMA_VERSION, alias="schemaVersion"
    )
    request_id: RequestId = Field(alias="requestId")
    frame_seq: int = Field(default=0, alias="frameSeq", ge=0)
    mode: AnalysisMode = AnalysisMode.CAPTURE
    intent: PhotoIntent = PhotoIntent.AUTO
    session_id: str | None = Field(
        default=None, alias="sessionId", min_length=1, max_length=128
    )
    advice_epoch: int = Field(default=0, alias="adviceEpoch", ge=0)
    measurements: Measurements

    @field_validator("schema_version", "frame_seq", "advice_epoch", mode="before")
    @classmethod
    def integer_metadata_is_type_strict(cls, value: Any) -> Any:
        if type(value) is not int:
            raise ValueError("integer metadata cannot be a boolean or string")
        return value


class CanonicalScores(StrictModel):
    overall_score: int = Field(alias="overallScore", ge=0, le=100)
    composition_score: int = Field(alias="compositionScore", ge=0, le=100)
    lighting_score: int = Field(alias="lightingScore", ge=0, le=100)
    clarity_score: int = Field(alias="clarityScore", ge=0, le=100)
    color_score: int = Field(alias="colorScore", ge=0, le=100)


class CanonicalAction(StrictModel):
    action_code: str = Field(alias="actionCode", min_length=1, max_length=64)
    priority: CoachingPriority
    overlay: OverlayType
    params: dict[str, Any]


class CanonicalPlan(StrictModel):
    schema_version: Literal[SCHEMA_VERSION] = Field(alias="schemaVersion")
    scores: CanonicalScores
    actions: list[CanonicalAction] = Field(min_length=3, max_length=4)


class ActionSelection(StrictModel):
    """The complete, deliberately tiny FreeSolo output contract."""

    schema_version: Literal[SCHEMA_VERSION] = Field(alias="schemaVersion")
    action_codes: list[str] = Field(alias="actionCodes", min_length=3, max_length=3)

    @field_validator("schema_version", mode="before")
    @classmethod
    def schema_version_is_an_integer(cls, value: Any) -> Any:
        if type(value) is not int:
            raise ValueError("schemaVersion must be an integer")
        return value

    @field_validator("action_codes", mode="before")
    @classmethod
    def action_codes_are_unique_strings(cls, value: Any) -> Any:
        if not isinstance(value, list) or any(type(code) is not str for code in value):
            raise ValueError("actionCodes must be a list of strings")
        if len(set(value)) != len(value):
            raise ValueError("actionCodes must be unique")
        return value


class CoachingStep(StrictModel):
    title: str = Field(min_length=1, max_length=80)
    instruction: str = Field(min_length=1, max_length=280)
    priority: CoachingPriority
    overlay: OverlayType


class PhotoAnalysis(StrictModel):
    """Response shape consumed by Flutter's ``PhotoAnalysis`` class."""

    overall_score: int = Field(alias="overallScore", ge=0, le=100)
    composition_score: int = Field(alias="compositionScore", ge=0, le=100)
    lighting_score: int = Field(alias="lightingScore", ge=0, le=100)
    clarity_score: int = Field(alias="clarityScore", ge=0, le=100)
    color_score: int = Field(alias="colorScore", ge=0, le=100)
    steps: list[CoachingStep] = Field(min_length=3, max_length=4)
