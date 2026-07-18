"""Start the local API with the credential already stored by ``flash login``.

Run this file with FreeSolo Flash's managed Python interpreter. The API key is
copied directly into the Uvicorn child environment and is never printed or
placed on a command line.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from flash.client.config import load_credentials


DEPLOYMENT_PATH = Path(__file__).with_name("deployment.json")


def _load_deployment() -> dict[str, Any]:
    try:
        deployment = json.loads(DEPLOYMENT_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(
            f"Could not read the deployment manifest ({type(exc).__name__})."
        ) from None
    required = {
        "service",
        "apiVersion",
        "schemaVersion",
        "baseUrl",
        "modelRevision",
    }
    if type(deployment) is not dict or set(deployment) != required:
        raise SystemExit("The deployment manifest has an invalid shape.")
    if (
        deployment["service"] != "picture-perfect-analysis"
        or deployment["apiVersion"] != 1
        or deployment["schemaVersion"] != 1
    ):
        raise SystemExit("The deployment manifest has an incompatible API identity.")
    base_url = deployment["baseUrl"]
    model_revision = deployment["modelRevision"]
    if type(base_url) is not str or urlsplit(base_url).scheme != "https":
        raise SystemExit("The deployment manifest must use an HTTPS base URL.")
    if (
        type(model_revision) is not str
        or not model_revision
        or len(model_revision) > 256
        or any(not 0x21 <= ord(char) <= 0x7E for char in model_revision)
    ):
        raise SystemExit("The deployment manifest has an invalid model revision.")
    return deployment


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Start Picture Perfect with the saved Flash credential."
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        choices=("127.0.0.1",),
        help="Loopback address. This credentialed local API is never exposed to the LAN.",
    )
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument(
        "--allowed-origin",
        default="http://localhost:8765",
        help="Exact Flutter web origin allowed by CORS.",
    )
    return parser.parse_args()


def _probe_startup_model(
    *,
    backend_python: Path,
    repo_root: Path,
    deployment: dict[str, Any],
    child_environment: dict[str, str],
) -> str:
    command = [
        str(backend_python),
        "training/evaluate_policy_deployment.py",
        "--base-url",
        deployment["baseUrl"],
        "--model",
        deployment["modelRevision"],
        "--max-examples",
        "1",
        "--concurrency",
        "1",
        "--timeout",
        "25",
        "--retries",
        "0",
    ]
    try:
        completed = subprocess.run(
            command,
            cwd=repo_root,
            env=child_environment,
            capture_output=True,
            text=True,
            timeout=32,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable"
    if completed.returncode != 0:
        return "unavailable"
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return "unavailable"
    if type(report) is not dict or report.get("evaluableResponses") != 1:
        return "unavailable"
    return "validated" if report.get("exactSuccesses") == 1 else "responded-rejected"


def main() -> None:
    args = _arguments()
    deployment = _load_deployment()
    if not 1 <= args.port <= 65_535:
        raise SystemExit("--port must be between 1 and 65535")

    repo_root = Path(__file__).resolve().parent.parent
    backend_python = repo_root / ".venv-backend" / "bin" / "python"
    if not backend_python.is_file():
        raise SystemExit(
            "The backend virtual environment is missing. Expected "
            f"{backend_python}"
        )

    api_key = os.environ.get("FREESOLO_API_KEY", "").strip()
    if not api_key:
        try:
            api_key = str(load_credentials()[1] or "").strip()
        except Exception as exc:  # The message could contain credential context.
            raise SystemExit(
                f"Could not load the saved Flash credential ({type(exc).__name__}). "
                "Run `flash login` in this WSL distribution."
            ) from None
    if not api_key:
        raise SystemExit("No saved Flash API key was found. Run `flash login` first.")

    child_environment = os.environ.copy()
    child_environment.update(
        {
            "FREESOLO_OPENAI_BASE_URL": deployment["baseUrl"],
            "FREESOLO_API_KEY": api_key,
            "FREESOLO_MODEL": deployment["modelRevision"],
            "FREESOLO_ENABLE_PREVIEW": "false",
            "FREESOLO_CAPTURE_TIMEOUT_SECONDS": "5.0",
            "PICTUREPERFECT_ALLOWED_ORIGINS": args.allowed_origin,
        }
    )

    startup_model_status = _probe_startup_model(
        backend_python=backend_python,
        repo_root=repo_root,
        deployment=deployment,
        child_environment=child_environment,
    )
    child_environment["PICTUREPERFECT_STARTUP_MODEL_STATUS"] = (
        startup_model_status
    )
    if startup_model_status == "validated":
        print("The pinned FreeSolo model completed a validated startup warm-up.", flush=True)
    elif startup_model_status == "responded-rejected":
        print(
            "The pinned FreeSolo model responded; strict validation safely rejected "
            "its warm-up ranking.",
            flush=True,
        )
    else:
        print(
            "The pinned FreeSolo model did not answer the startup warm-up; "
            "capture requests will retry it with deterministic fallback.",
            flush=True,
        )

    os.chdir(repo_root)
    command = [
        str(backend_python),
        "-m",
        "uvicorn",
        "backend.app:app",
        "--host",
        args.host,
        "--port",
        str(args.port),
    ]
    os.execve(str(backend_python), command, child_environment)


if __name__ == "__main__":
    main()
