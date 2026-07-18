"""Canonical scoring plus fail-closed validation of model proposals.

The preferred implementation is shared with the FreeSolo training environment.
The local implementation keeps the serving package safe and usable when only
``backend/`` is deployed.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Any, Mapping

from .models import CanonicalPlan, Measurements, SCHEMA_VERSION

try:
    from training.photo_coach_environment import (
        canonical_analysis as _training_canonical_analysis,
    )
except (ImportError, ModuleNotFoundError):
    _training_canonical_analysis = None


PRIORITIES = ("urgent", "high", "medium", "low")

ACTION_PARAM_KEYS: dict[str, frozenset[str]] = {
    "LEVEL_HORIZON": frozenset(("degrees", "direction")),
    "PLACE_SUBJECT_THIRDS": frozenset(
        (
            "targetX",
            "targetY",
            "moveXPct",
            "moveXDirection",
            "moveYPct",
            "moveYDirection",
        )
    ),
    "BRIGHTEN_EXPOSURE": frozenset(("ev",)),
    "REDUCE_EXPOSURE": frozenset(("ev",)),
    "RECOVER_HIGHLIGHTS": frozenset(("ev",)),
    "OPEN_SHADOWS": frozenset(("method", "fillSide")),
    "ADD_TONAL_SEPARATION": frozenset(("moveDegrees",)),
    "SOFTEN_CONTRAST": frozenset(("method",)),
    "LOCK_FOCUS": frozenset(("xPct", "yPct")),
    "REDUCE_NOISE": frozenset(("isoSteps",)),
    "NEUTRALIZE_COLOR_CAST": frozenset(("reference",)),
    "STRENGTHEN_COLOR": frozenset(("method",)),
    "TAME_SATURATION": frozenset(("percent",)),
    "KEEP_LEVEL": frozenset(("toleranceDegrees",)),
    "PROTECT_HIGHLIGHTS": frozenset(("holdExposure",)),
    "STEADY_SHUTTER": frozenset(("technique",)),
}
MODEL_ACTION_CODES = frozenset(ACTION_PARAM_KEYS) - {"STEADY_SHUTTER"}


@dataclass(frozen=True)
class ValidationOutcome:
    plan: CanonicalPlan
    model_accepted: bool
    reason: str


@dataclass(frozen=True)
class _Candidate:
    severity: float
    order: int
    code: str
    priority: str
    overlay: str
    params: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "actionCode": self.code,
            "priority": self.priority,
            "overlay": self.overlay,
            "params": self.params,
        }


def payload_for_measurements(
    measurements: Measurements,
    *,
    mode: str = "capture",
    intent: str = "auto",
) -> dict[str, Any]:
    capture_phase = {"preview": "preview", "capture": "captured"}.get(mode)
    if capture_phase is None:
        raise ValueError("mode must be preview or capture")
    training_intent = "general" if intent == "auto" else intent
    return {
        "schemaVersion": SCHEMA_VERSION,
        "stats": measurements.model_dump(by_alias=True, exclude_none=False),
        "context": {
            "intent": training_intent,
            "scene": {"capturePhase": capture_phase},
        },
    }


def canonical_analysis(payload: Mapping[str, Any]) -> dict[str, Any]:
    if _training_canonical_analysis is not None:
        return _training_canonical_analysis(payload)
    return _local_canonical_analysis(payload)


def expected_plan(payload: Mapping[str, Any]) -> CanonicalPlan:
    return CanonicalPlan.model_validate(canonical_analysis(payload))


def validate_or_fallback(
    candidate: str | Mapping[str, Any] | None,
    expected: CanonicalPlan,
) -> ValidationOutcome:
    """Accept exactly the canonical first three ordered action codes.

    Scores, parameters, directions, overlays, priorities, and rendered copy are
    never accepted from the model; they remain canonical backend data.
    """

    canonical_three = expected.model_copy(update={"actions": expected.actions[:3]})
    if candidate is None:
        return ValidationOutcome(canonical_three, False, "model unavailable")
    try:
        raw = json.loads(candidate) if isinstance(candidate, str) else dict(candidate)
    except (json.JSONDecodeError, TypeError, ValueError) as exc:
        return ValidationOutcome(canonical_three, False, f"invalid model output: {type(exc).__name__}")

    if not isinstance(raw, dict) or set(raw) != {"schemaVersion", "actionCodes"}:
        return ValidationOutcome(canonical_three, False, "model output used unsupported keys")
    if type(raw.get("schemaVersion")) is not int or raw["schemaVersion"] != SCHEMA_VERSION:
        return ValidationOutcome(canonical_three, False, "model schemaVersion was invalid")
    codes = raw.get("actionCodes")
    if (
        type(codes) is not list
        or len(codes) != 3
        or any(type(code) is not str for code in codes)
        or len(set(codes)) != len(codes)
    ):
        return ValidationOutcome(canonical_three, False, "model actionCodes shape was invalid")
    if any(code not in MODEL_ACTION_CODES for code in codes):
        return ValidationOutcome(canonical_three, False, "model output used unsupported action code")

    expected_codes = [action.action_code for action in expected.actions[:3]]
    expected_raw = {"schemaVersion": SCHEMA_VERSION, "actionCodes": expected_codes}
    if not _strict_equal(raw, expected_raw):
        return ValidationOutcome(canonical_three, False, "model action codes failed canonical validation")

    # Always return canonical objects; no model-controlled values reach rendering.
    return ValidationOutcome(canonical_three, True, "canonical model output accepted")


def _strict_equal(actual: Any, expected: Any) -> bool:
    """Recursively compare JSON values without Python's bool/int equality."""

    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return set(actual) == set(expected) and all(
            _strict_equal(actual[key], value) for key, value in expected.items()
        )
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(
            _strict_equal(left, right) for left, right in zip(actual, expected, strict=True)
        )
    return actual == expected


def _clamp(value: float, low: float = 0.0, high: float = 100.0) -> float:
    return max(low, min(high, value))


def _round(value: float) -> int:
    return int(math.floor(value + 0.5))


def _one_decimal(value: float, maximum: float | None = None) -> float:
    if maximum is not None:
        value = min(value, maximum)
    return float(f"{value:.1f}")


def _plateau(
    value: float,
    ideal_start: float,
    ideal_end: float,
    low: float,
    high: float,
) -> float:
    if ideal_start <= value <= ideal_end:
        return 100.0
    if value < ideal_start:
        return _clamp((value - low) / (ideal_start - low) * 100.0)
    return _clamp((high - value) / (high - ideal_end) * 100.0)


def _third(value: float) -> float:
    return 1.0 / 3.0 if value <= 0.5 else 2.0 / 3.0


def _priority(severity: float) -> str:
    if severity >= 72.0:
        return "urgent"
    if severity >= 45.0:
        return "high"
    if severity >= 22.0:
        return "medium"
    return "low"


def _stops(darker: float, brighter: float) -> float:
    return _one_decimal(_clamp(math.log2(brighter / max(darker, 0.03)), 0.3, 2.0))


def _candidate(
    severity: float,
    order: int,
    code: str,
    overlay: str,
    params: dict[str, Any],
) -> _Candidate:
    severity = _clamp(severity)
    return _Candidate(severity, order, code, _priority(severity), overlay, params)


def _measure(stats: Mapping[str, Any]) -> dict[str, float | None]:
    x, y = float(stats["subjectX"]), float(stats["subjectY"])
    thirds_distance = math.hypot(x - _third(x), y - _third(y))
    center_distance = math.hypot(x - 0.5, y - 0.5)
    placement = _clamp(max(100.0 - thirds_distance * 180.0, 92.0 - center_distance * 180.0))
    edge = _clamp(min(x, 1.0 - x, y, 1.0 - y) / 0.12 * 100.0)
    tilt = stats.get("horizonTiltDegrees")
    level = None
    if tilt is not None:
        level = _clamp(100.0 - _clamp(abs(float(tilt)) - 1.0, 0.0, 11.0) / 11.0 * 100.0)
    composition = (
        placement * 0.85 + edge * 0.15
        if level is None
        else placement * 0.72 + edge * 0.13 + level * 0.15
    )

    exposure = _plateau(float(stats["brightness"]), 0.45, 0.60, 0.0, 1.0)
    contrast = _plateau(float(stats["contrast"]), 0.38, 0.68, 0.05, 0.95)
    clipping = _clamp(
        100.0
        - (float(stats["highlightClipping"]) + float(stats["shadowClipping"]))
        * 350.0
    )
    lighting = exposure * 0.50 + contrast * 0.20 + clipping * 0.30
    detail = _clamp(float(stats["sharpness"]) / 0.85 * 100.0)
    clean = _clamp((1.0 - float(stats.get("noise", 0.0))) * 100.0)
    clarity = detail * 0.78 + clean * 0.22
    saturation = _plateau(float(stats["saturation"]), 0.32, 0.68, 0.0, 1.0)
    neutral = _clamp((1.0 - float(stats.get("colorCast", 0.0))) * 100.0)
    color = saturation * 0.65 + neutral * 0.35
    overall = composition * 0.30 + lighting * 0.30 + clarity * 0.25 + color * 0.15
    return {
        "overall": _clamp(overall),
        "composition": _clamp(composition),
        "lighting": _clamp(lighting),
        "clarity": _clamp(clarity),
        "color": _clamp(color),
        "placement": placement,
        "edge": edge,
        "level": level,
        "exposure": exposure,
        "contrast": contrast,
        "clipping": clipping,
        "detail": detail,
        "clean": clean,
        "saturation": saturation,
        "neutral": neutral,
    }


def _candidates(stats: Mapping[str, Any], m: Mapping[str, float | None]) -> list[_Candidate]:
    result: list[_Candidate] = []
    x, y = float(stats["subjectX"]), float(stats["subjectY"])
    tilt = stats.get("horizonTiltDegrees")
    if tilt is not None and abs(float(tilt)) > 1.5:
        result.append(
            _candidate(
                100.0 - float(m["level"] or 0.0),
                0,
                "LEVEL_HORIZON",
                "level",
                {
                    "degrees": _one_decimal(abs(float(tilt)), 15.0),
                    "direction": "counterClockwise" if float(tilt) > 0 else "clockwise",
                },
            )
        )
    placement, edge = float(m["placement"] or 0.0), float(m["edge"] or 0.0)
    if placement < 84.0 or edge < 70.0:
        target_x, target_y = _third(x), _third(y)
        dx, dy = target_x - x, target_y - y
        x_pct, y_pct = _round(abs(dx) * 100.0), _round(abs(dy) * 100.0)
        result.append(
            _candidate(
                max(100.0 - placement, 100.0 - edge),
                1,
                "PLACE_SUBJECT_THIRDS",
                "ruleOfThirds",
                {
                    "targetX": _one_decimal(target_x * 100.0),
                    "targetY": _one_decimal(target_y * 100.0),
                    "moveXPct": x_pct,
                    "moveXDirection": "none" if x_pct < 2 else "left" if dx < 0 else "right",
                    "moveYPct": y_pct,
                    "moveYDirection": "none" if y_pct < 2 else "up" if dy < 0 else "down",
                },
            )
        )
    brightness = float(stats["brightness"])
    if brightness < 0.42:
        result.append(_candidate(100.0 - float(m["exposure"] or 0.0), 2, "BRIGHTEN_EXPOSURE", "exposure", {"ev": _stops(brightness, 0.50)}))
    elif brightness > 0.64:
        result.append(_candidate(100.0 - float(m["exposure"] or 0.0), 2, "REDUCE_EXPOSURE", "exposure", {"ev": _stops(0.54, brightness)}))
    elif float(stats["highlightClipping"]) > 0.025:
        ev = 0.7 if float(stats["highlightClipping"]) > 0.12 else 0.3
        result.append(_candidate(100.0 - float(m["clipping"] or 0.0), 3, "RECOVER_HIGHLIGHTS", "exposure", {"ev": ev}))
    elif float(stats["shadowClipping"]) > 0.035:
        result.append(_candidate(100.0 - float(m["clipping"] or 0.0), 3, "OPEN_SHADOWS", "exposure", {"method": "turnSubjectOrAddFill", "fillSide": "cameraLeft"}))

    contrast = float(stats["contrast"])
    if contrast < 0.30:
        result.append(_candidate(100.0 - float(m["contrast"] or 0.0), 4, "ADD_TONAL_SEPARATION", "subjectGuide", {"moveDegrees": 30}))
    elif contrast > 0.76:
        result.append(_candidate(100.0 - float(m["contrast"] or 0.0), 4, "SOFTEN_CONTRAST", "subjectGuide", {"method": "openShadeOrWhiteReflector"}))
    if float(stats["sharpness"]) < 0.70:
        result.append(_candidate(100.0 - float(m["detail"] or 0.0), 5, "LOCK_FOCUS", "focus", {"xPct": _round(x * 100.0), "yPct": _round(y * 100.0)}))
    if float(stats.get("noise", 0.0)) > 0.18:
        result.append(_candidate(100.0 - float(m["clean"] or 0.0), 6, "REDUCE_NOISE", "none", {"isoSteps": 1}))
    if float(stats.get("colorCast", 0.0)) > 0.12:
        result.append(_candidate(100.0 - float(m["neutral"] or 0.0), 7, "NEUTRALIZE_COLOR_CAST", "colorBalance", {"reference": "neutralWhiteOrGray"}))
    elif float(stats["saturation"]) < 0.27:
        result.append(_candidate(100.0 - float(m["saturation"] or 0.0), 8, "STRENGTHEN_COLOR", "colorBalance", {"method": "cleanDaylightNoMixedLight"}))
    elif float(stats["saturation"]) > 0.74:
        result.append(_candidate(100.0 - float(m["saturation"] or 0.0), 8, "TAME_SATURATION", "colorBalance", {"percent": 10}))
    return result


def _fallbacks(stats: Mapping[str, Any]) -> list[_Candidate]:
    x, y = _round(float(stats["subjectX"]) * 100.0), _round(float(stats["subjectY"]) * 100.0)
    return [
        _Candidate(0.0, 9, "LOCK_FOCUS", "low", "focus", {"xPct": x, "yPct": y}),
        _Candidate(0.0, 10, "KEEP_LEVEL", "low", "level", {"toleranceDegrees": 1}),
        _Candidate(0.0, 11, "PROTECT_HIGHLIGHTS", "low", "exposure", {"holdExposure": True}),
        _Candidate(0.0, 12, "STEADY_SHUTTER", "low", "none", {"technique": "braceExhalePress"}),
    ]


def _local_canonical_analysis(payload: Mapping[str, Any]) -> dict[str, Any]:
    if payload.get("schemaVersion") != SCHEMA_VERSION or not isinstance(payload.get("stats"), Mapping):
        raise ValueError("expected schemaVersion 1 and a stats object")
    stats = dict(payload["stats"])
    stats.setdefault("noise", 0.0)
    stats.setdefault("colorCast", 0.0)
    stats.setdefault("horizonTiltDegrees", None)
    m = _measure(stats)
    candidates = _candidates(stats, m)
    candidates.sort(key=lambda item: (PRIORITIES.index(item.priority), -item.severity, item.order))
    selected: list[_Candidate] = []
    overlays: set[str] = set()
    for item in candidates:
        if item.overlay in overlays:
            continue
        selected.append(item)
        overlays.add(item.overlay)
        if len(selected) == 4:
            break
    for item in _fallbacks(stats):
        if len(selected) >= 3:
            break
        if item.overlay not in overlays:
            selected.append(item)
            overlays.add(item.overlay)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "scores": {
            "overallScore": _round(float(m["overall"] or 0.0)),
            "compositionScore": _round(float(m["composition"] or 0.0)),
            "lightingScore": _round(float(m["lighting"] or 0.0)),
            "clarityScore": _round(float(m["clarity"] or 0.0)),
            "colorScore": _round(float(m["color"] or 0.0)),
        },
        "actions": [item.to_dict() for item in selected],
    }
