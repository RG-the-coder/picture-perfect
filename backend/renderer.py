"""Render validated action codes through a vetted, safely varied copy bank."""

from __future__ import annotations

import hashlib
from collections.abc import Callable
from typing import Any

from .canonical import ACTION_PARAM_KEYS
from .models import CanonicalAction, CanonicalPlan, CoachingStep, PhotoAnalysis


CopyRenderer = Callable[[dict[str, Any]], tuple[str, str]]


def _number(value: Any) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("template parameter must be numeric")
    if float(value).is_integer():
        return str(int(value))
    return f"{float(value):.1f}"


def _direction(value: Any) -> str:
    choices = {
        "clockwise": "clockwise",
        "counterClockwise": "counter-clockwise",
        "left": "left",
        "right": "right",
        "up": "up",
        "down": "down",
    }
    if value not in choices:
        raise ValueError("unsupported direction")
    return choices[value]


def _movement(params: dict[str, Any]) -> str:
    parts: list[str] = []
    if params["moveXDirection"] != "none":
        parts.append(f'{_number(params["moveXPct"])}% {_direction(params["moveXDirection"])}')
    if params["moveYDirection"] != "none":
        parts.append(f'{_number(params["moveYPct"])}% {_direction(params["moveYDirection"])}')
    if not parts:
        return (
            f'to {_number(params["targetX"])}% from the left and '
            f'{_number(params["targetY"])}% from the top'
        )
    return " and ".join(parts)


def _level_1(p: dict[str, Any]) -> tuple[str, str]:
    return (
        "Level the horizon",
        f'Rotate the camera {_number(p["degrees"])}° {_direction(p["direction"])} until the level line is centered.',
    )


def _level_2(p: dict[str, Any]) -> tuple[str, str]:
    return (
        "Straighten the frame",
        f'Correct the camera {_number(p["degrees"])}° {_direction(p["direction"])} and stop when the level guide centers.',
    )


def _thirds_1(p: dict[str, Any]) -> tuple[str, str]:
    return (
        "Place the subject on thirds",
        f"Shift the framing so the subject moves {_movement(p)} onto the nearest grid intersection.",
    )


def _thirds_2(p: dict[str, Any]) -> tuple[str, str]:
    return (
        "Refine subject placement",
        f"Reframe by moving the subject {_movement(p)} toward the closest rule-of-thirds point.",
    )


def _brighten_1(p: dict[str, Any]) -> tuple[str, str]:
    return ("Brighten the exposure", f'Raise exposure by {_number(p["ev"])} EV, then keep the meter near center.')


def _brighten_2(p: dict[str, Any]) -> tuple[str, str]:
    return ("Lift the exposure", f'Add {_number(p["ev"])} EV and confirm the exposure meter settles near center.')


def _reduce_1(p: dict[str, Any]) -> tuple[str, str]:
    return ("Reduce the exposure", f'Lower exposure by {_number(p["ev"])} EV, then keep the meter just below center.')


def _reduce_2(p: dict[str, Any]) -> tuple[str, str]:
    return ("Darken the frame", f'Remove {_number(p["ev"])} EV and check that the exposure meter sits just below center.')


def _highlights_1(p: dict[str, Any]) -> tuple[str, str]:
    return ("Recover bright detail", f'Lower exposure by {_number(p["ev"])} EV until the highlight warning disappears.')


def _highlights_2(p: dict[str, Any]) -> tuple[str, str]:
    return ("Protect the highlights", f'Pull exposure down {_number(p["ev"])} EV and verify that clipped-highlight warnings clear.')


def _shadows_1(_: dict[str, Any]) -> tuple[str, str]:
    return ("Open the shadows", "Turn the subject toward the main light or add fill light from camera-left.")


def _shadows_2(_: dict[str, Any]) -> tuple[str, str]:
    return ("Lift shadow detail", "Face the subject toward the key light, or introduce fill from camera-left.")


def _separation_1(p: dict[str, Any]) -> tuple[str, str]:
    return ("Add tonal separation", f'Move {_number(p["moveDegrees"])}° to one side of the main light to create visible highlights and shadows.')


def _separation_2(p: dict[str, Any]) -> tuple[str, str]:
    return ("Shape the light", f'Shift {_number(p["moveDegrees"])}° sideways from the main light so light and shadow separate clearly.')


def _soften_1(_: dict[str, Any]) -> tuple[str, str]:
    return ("Soften the contrast", "Move the subject into open shade or place a white reflector opposite the main light.")


def _soften_2(_: dict[str, Any]) -> tuple[str, str]:
    return ("Reduce harsh contrast", "Use open shade, or add a white reflector across from the main light.")


def _focus_1(p: dict[str, Any]) -> tuple[str, str]:
    return ("Lock focus on the subject", f'Tap the subject at {_number(p["xPct"])}% from the left and {_number(p["yPct"])}% from the top, then wait for focus lock.')


def _focus_2(p: dict[str, Any]) -> tuple[str, str]:
    return ("Set focus precisely", f'Place the focus point {_number(p["xPct"])}% from the left and {_number(p["yPct"])}% from the top, then hold until it locks.')


def _noise_1(p: dict[str, Any]) -> tuple[str, str]:
    return ("Reduce visible noise", f'Add light, then lower ISO by {_number(p["isoSteps"])} step while keeping the camera steady.')


def _noise_2(p: dict[str, Any]) -> tuple[str, str]:
    return ("Clean up the image", f'Increase the light on the subject and drop ISO {_number(p["isoSteps"])} step without moving the camera.')


def _neutral_1(_: dict[str, Any]) -> tuple[str, str]:
    return ("Neutralize the color cast", "Aim at a neutral white or gray surface and lock white balance before reframing.")


def _neutral_2(_: dict[str, Any]) -> tuple[str, str]:
    return ("Correct white balance", "Use a neutral white or gray reference, lock white balance, and then restore the framing.")


def _color_1(_: dict[str, Any]) -> tuple[str, str]:
    return ("Strengthen the color", "Move the subject toward clean daylight and avoid mixing indoor and window light.")


def _color_2(_: dict[str, Any]) -> tuple[str, str]:
    return ("Improve color separation", "Use clean daylight on the subject and remove mixed indoor and window lighting.")


def _saturation_1(p: dict[str, Any]) -> tuple[str, str]:
    return ("Tame intense color", f'Reduce saturation by {_number(p["percent"])}% before capture.')


def _saturation_2(p: dict[str, Any]) -> tuple[str, str]:
    return ("Reduce oversaturation", f'Pull saturation down {_number(p["percent"])}% before taking the photo.')


def _keep_level_1(p: dict[str, Any]) -> tuple[str, str]:
    return ("Keep the camera level", f'Hold the horizon within {_number(p["toleranceDegrees"])}° of the centered level guide.')


def _keep_level_2(p: dict[str, Any]) -> tuple[str, str]:
    return ("Preserve the level frame", f'Keep the level indicator centered within {_number(p["toleranceDegrees"])}° while shooting.')


def _protect_1(_: dict[str, Any]) -> tuple[str, str]:
    return ("Protect highlight detail", "Hold the current exposure and confirm no highlight warning is visible.")


def _protect_2(_: dict[str, Any]) -> tuple[str, str]:
    return ("Keep bright detail", "Leave exposure where it is and check that no clipped-highlight warning appears.")


def _steady_1(_: dict[str, Any]) -> tuple[str, str]:
    return ("Take the clean frame", "Brace both elbows, exhale slowly, and press the shutter without moving the camera.")


def _steady_2(_: dict[str, Any]) -> tuple[str, str]:
    return ("Steady the capture", "Plant both elbows, breathe out, and squeeze the shutter while holding the camera still.")


TEMPLATES: dict[str, tuple[CopyRenderer, ...]] = {
    "LEVEL_HORIZON": (_level_1, _level_2),
    "PLACE_SUBJECT_THIRDS": (_thirds_1, _thirds_2),
    "BRIGHTEN_EXPOSURE": (_brighten_1, _brighten_2),
    "REDUCE_EXPOSURE": (_reduce_1, _reduce_2),
    "RECOVER_HIGHLIGHTS": (_highlights_1, _highlights_2),
    "OPEN_SHADOWS": (_shadows_1, _shadows_2),
    "ADD_TONAL_SEPARATION": (_separation_1, _separation_2),
    "SOFTEN_CONTRAST": (_soften_1, _soften_2),
    "LOCK_FOCUS": (_focus_1, _focus_2),
    "REDUCE_NOISE": (_noise_1, _noise_2),
    "NEUTRALIZE_COLOR_CAST": (_neutral_1, _neutral_2),
    "STRENGTHEN_COLOR": (_color_1, _color_2),
    "TAME_SATURATION": (_saturation_1, _saturation_2),
    "KEEP_LEVEL": (_keep_level_1, _keep_level_2),
    "PROTECT_HIGHLIGHTS": (_protect_1, _protect_2),
    "STEADY_SHUTTER": (_steady_1, _steady_2),
}


def _variant_index(seed: str, action_code: str, advice_epoch: int, size: int) -> int:
    material = f"{seed}\x1f{action_code}\x1f{advice_epoch}".encode("utf-8")
    digest = hashlib.blake2s(material, digest_size=8).digest()
    return int.from_bytes(digest, "big") % size


def render_action(action: CanonicalAction, *, seed: str, advice_epoch: int) -> CoachingStep:
    code = action.action_code
    expected_keys = ACTION_PARAM_KEYS.get(code)
    variants = TEMPLATES.get(code)
    if expected_keys is None or variants is None:
        raise ValueError(f"unsupported canonical action: {code}")
    if set(action.params) != expected_keys:
        raise ValueError(f"invalid parameters for canonical action: {code}")
    renderer = variants[_variant_index(seed, code, advice_epoch, len(variants))]
    title, instruction = renderer(action.params)
    return CoachingStep(
        title=title,
        instruction=instruction,
        priority=action.priority,
        overlay=action.overlay,
    )


def render_plan(plan: CanonicalPlan, *, seed: str, advice_epoch: int = 0) -> PhotoAnalysis:
    scores = plan.scores
    return PhotoAnalysis(
        overallScore=scores.overall_score,
        compositionScore=scores.composition_score,
        lightingScore=scores.lighting_score,
        clarityScore=scores.clarity_score,
        colorScore=scores.color_score,
        steps=[
            render_action(action, seed=seed, advice_epoch=advice_epoch)
            for action in plan.actions
        ],
    )
