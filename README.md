# Picture Perfect

Picture Perfect is a camera-first Flutter web app that turns a photo into a
clear, prioritized shot plan. It can open the browser camera, provide
lightweight near-real-time feedback, capture a frame, or analyze an uploaded
image.

Photo pixels and provider credentials never leave their respective trusted
boundaries. The browser profiles the image locally and, when configured, sends
only normalized numeric measurements to the Picture Perfect backend. The app
automatically uses its deterministic on-device engine if the backend is absent,
slow, or returns an invalid response.

## Included

- Live browser camera preview with front/back switching
- Fully local Live Assist checks for exposure and visible sharpness
- Upload fallback with image-type and 18 MB size validation
- Local pixel profiling for luminance, contrast, clipping, saturation,
  sharpness, and visual-weight placement
- 0–100 scores for composition, lighting, clarity, color, and the overall frame
- Three prioritized coaching steps with a zero-network fallback
- Pinned FreeSolo Qwen3.5-4B policy ranking with deterministic validation
- Visual guides for thirds, subject placement, level, exposure, focus, and
  color balance
- Copyable shot plans, guided-retake mode, and vetted wording variants
- Responsive desktop/mobile layouts and accessible live regions

## Run locally

Camera access works on `localhost` or a deployed HTTPS origin.

For the trained model and app together, double-click
`run_picture_perfect.cmd`, or run the same policy-safe launcher from PowerShell:

```powershell
.\run_picture_perfect.cmd
```

The launcher reads the credential already stored by `flash login` inside
Ubuntu-24.04, starts the pinned 4B backend, waits for its health check, and then
starts Flutter on port 8765. The credential is never copied into Flutter or
placed on a command line. The backend process started by the launcher is
stopped when Flutter exits. To avoid OneDrive and Impeller path failures,
generated Flutter output is redirected through a unique short junction into
`%LOCALAPPDATA%\PicturePerfect\flutter_runs`. A stale process can therefore
never lock the next launch. The launcher uses its own private Flutter settings
directory, so it never changes your global Flutter config.

For the fully local fallback:

```powershell
.\flutter_safe.cmd pub get
.\flutter_safe.cmd run -d chrome
```

To start both pieces manually instead, first start the sibling backend on port
8000 with `PICTUREPERFECT_ALLOWED_ORIGINS=http://localhost:8765`, then run:

```powershell
.\flutter_safe.cmd run -d chrome --web-port 8765 --dart-define=PICTUREPERFECT_API_BASE_URL=http://localhost:8000
```

The FreeSolo API key belongs only in the backend process. Never add it to a
`--dart-define`, Flutter source file, or web build.

## Verify and build

```powershell
.\flutter_safe.cmd analyze
.\flutter_safe.cmd test
.\flutter_safe.cmd build web --release --dart-define=PICTUREPERFECT_API_BASE_URL=https://your-api.example
```

`flutter_safe.cmd` applies the same isolated Flutter settings and local build
cache as the app launcher. Tests additionally run from a synchronized local
mirror because Flutter 3.44 hard-codes one test-assets path. Release output is available through
`.picture_perfect_build/web` (physically under `%LOCALAPPDATA%`).

## Architecture

- `lib/capture/` owns browser file selection, camera preview, frame capture,
  camera switching, and track cleanup.
- `lib/analysis/pixel_profiler.dart` derives neutral measurements from a local,
  reduced-size copy of the image.
- `lib/analysis/photo_analysis_api.dart` sends only structured measurements,
  strictly parses the backend response, and preserves provenance headers.
- `lib/analysis/hybrid_photo_analyzer.dart` uses the backend for completed
  captures and fails closed to the local analysis engine.
- `lib/analysis/picture_analysis_engine.dart` remains the deterministic,
  zero-network fallback.
- `lib/studio_page.dart` owns the complete capture-to-results flow.

Live Assist remains entirely local. Completed captures use the same
`ImageStats` contract with the backend; encoded image bytes are never present in
that request.

## Privacy and limits

Images stay in browser memory for the active session and camera tracks stop as
soon as the camera view closes. When a backend URL is configured, brightness,
contrast, clipping, sharpness, saturation, subject-position, and color-cast
measurements are sent to it. Noise and horizon are currently sent as safe
unknown defaults (`0` and `null`) until calibrated detectors can distinguish
real noise from texture and real horizons from arbitrary edges.

The 4B model ranks three action codes but never sees pixels or controls scores,
correction amounts, overlays, priorities, or wording. The backend rejects any
ranking that differs from its canonical safety policy. Recommendations remain
practical guidance rather than guarantees because measurement and
scene-understanding errors are still possible.
