# Picture Perfect backend

Requires Python 3.11 or newer.

This service accepts the existing browser-derived image measurements, asks an
optional deployed FreeSolo adapter for ordered action codes, validates those codes
against deterministic rules, and renders vetted coaching text.

## Configure

Install `backend/requirements.txt`, then set these only in the server process:

```text
FREESOLO_OPENAI_BASE_URL=https://clado-ai--freesolo-lora-serving.modal.run/v1
FREESOLO_API_KEY=<server-side-key>
FREESOLO_MODEL=flash-1784397077-b6e293a2@final.85e6c1d65d7fdf86571a7fe8d27147f8b83845fc
PICTUREPERFECT_ALLOWED_ORIGINS=http://localhost:8765
```

`backend/deployment.json` is the single launcher/runtime manifest for the
endpoint, service identity, and pinned model. `FREESOLO_MODEL` should be the immutable revision reported by
`flash deployments --json`, rather than the movable run alias
`flash-1784397077-b6e293a2`. The selected Qwen3.5-4B SFT adapter scored 491/512
(95.90%) exact ordered matches on the synthetic held-out policy set, with no
parse, schema, or transport errors. Every non-exact response is rejected and
replaced by the canonical deterministic plan. If any variable is absent, the
API remains available using that fallback.

`PICTUREPERFECT_ALLOWED_ORIGINS` is a comma-separated allowlist of exact Flutter
web origins. Leave it empty when the frontend is served from the same origin.
The API exposes only its request, analysis-source, and model-revision headers to
allowed browser clients; wildcard origins are deliberately unsupported.

Optional settings:

```text
FREESOLO_ENABLE_PREVIEW=false
FREESOLO_PREVIEW_TIMEOUT_SECONDS=1.2
FREESOLO_CAPTURE_TIMEOUT_SECONDS=5.0
FREESOLO_MAX_TOKENS=128
```

Preview requests use the deterministic engine by default, so the live camera
path does not wait on model inference. Capture requests may use the
configured FreeSolo deployment and have a strict end-to-end five-second model
deadline. Set `FREESOLO_ENABLE_PREVIEW=true` only when
you intentionally want remote preview inference; its calls retain the preview
timeout above. The preview switch accepts only `true` or `false` (case
insensitive) and rejects invalid values at startup.

The saved-credential runner performs one 25-second startup-only warm-up
before Uvicorn becomes healthy. This absorbs a cold deployment without
loosening the five-second deadline for real capture requests. Health reports
`startupModelStatus` as `validated`, `responded-rejected`, or `unavailable`;
the latter two remain safe because only canonical backend output is served.

Start it from the repository root:

```shell
uvicorn backend.app:app --host 127.0.0.1 --port 8000
```

For local development, the Flutter app's `run_picture_perfect.cmd` launcher
starts this service automatically. It invokes `backend/run_local_with_flash.py`
with Flash's managed Python interpreter, loads the credential saved by
`flash login` without printing it, and pins the selected model and CORS origin.

That address is intentionally local-only. In a container or production host,
bind to `0.0.0.0` behind an HTTPS reverse proxy with authentication, request
limits, and narrowly configured CORS for the actual Flutter web origin.

## Request

`POST /v1/photo-analyses` with JSON:

```json
{
  "schemaVersion": 1,
  "requestId": "frame-42",
  "frameSeq": 42,
  "mode": "preview",
  "intent": "auto",
  "sessionId": "camera-session-1",
  "adviceEpoch": 0,
  "measurements": {
    "width": 640,
    "height": 480,
    "brightness": 0.3,
    "contrast": 0.5,
    "sharpness": 0.8,
    "saturation": 0.5,
    "highlightClipping": 0.0,
    "shadowClipping": 0.08,
    "subjectX": 0.5,
    "subjectY": 0.5,
    "noise": 0.05,
    "colorCast": 0.02,
    "horizonTiltDegrees": null
  }
}
```

The response is exactly the Flutter `PhotoAnalysis` shape: five scores and
exactly three `{title, instruction, priority, overlay}` steps. The
`X-Analysis-Source` header is `freesolo-validated` only when the model returned
the exact canonical ordered action codes; otherwise it is
`deterministic-fallback`. `X-Model-Revision` is included only on a validated
model result and omitted otherwise.
`X-Model-Attempted` and `X-Model-Responded` distinguish a safely rejected
model answer from a provider timeout for startup reachability diagnostics.

FreeSolo requests use its supported `response_format: {"type":"json_object"}`
mode. That mode guarantees JSON syntax, not the application contract. The
backend therefore still requires exactly three distinct, allowed action codes
in canonical order; every malformed, extra, missing, or incorrect result is
discarded in favor of the deterministic fallback.

`adviceEpoch` may be incremented to select another vetted wording. Measurements,
directions, amounts, and action meaning do not vary.
