"""wings-accel patch installer.

Usage:
    python install.py --features '{"vllm":{"version":"0.12.rc1","features":["speculative_decode","sparse_kv"]}}'

Reads the WINGS_ENGINE_PATCH_OPTIONS JSON, extracts engine/version/features,
then installs the corresponding whl packages from wings_engine_patch/.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ACCEL_DIR = Path(__file__).resolve().parent
PATCH_DIR = ACCEL_DIR / "wings_engine_patch"
SUPPORTED_FEATURES_FILE = ACCEL_DIR / "supported_features.json"


def _load_supported_features() -> dict:
    if not SUPPORTED_FEATURES_FILE.exists():
        print(f"[wings-accel] WARNING: {SUPPORTED_FEATURES_FILE} not found, skipping validation")
        return {}
    with open(SUPPORTED_FEATURES_FILE, encoding="utf-8") as f:
        return json.load(f)


def _install_whls(feature_names: list[str]) -> None:
    """Install whl files from wings_engine_patch/ directory."""
    if not PATCH_DIR.exists():
        print(f"[wings-accel] ERROR: patch directory {PATCH_DIR} not found")
        sys.exit(1)

    whls = list(PATCH_DIR.glob("*.whl"))
    if not whls:
        print(f"[wings-accel] WARNING: no .whl files found in {PATCH_DIR}")
        return

    print(f"[wings-accel] Installing {len(whls)} whl package(s) for features: {feature_names}")
    cmd = [sys.executable, "-m", "pip", "install"] + [str(w) for w in whls]
    subprocess.check_call(cmd)
    print("[wings-accel] whl installation complete")


def main() -> None:
    parser = argparse.ArgumentParser(description="Install accel patches based on features config")
    parser.add_argument(
        "--features",
        required=True,
        help="WINGS_ENGINE_PATCH_OPTIONS JSON string",
    )
    args = parser.parse_args()

    try:
        options = json.loads(args.features)
    except json.JSONDecodeError as e:
        print(f"[wings-accel] ERROR: invalid JSON in --features: {e}")
        sys.exit(1)

    if not isinstance(options, dict) or not options:
        print("[wings-accel] ERROR: --features must be a non-empty JSON object")
        sys.exit(1)

    supported = _load_supported_features()

    for engine, config in options.items():
        if not isinstance(config, dict):
            print(f"[wings-accel] ERROR: config for engine '{engine}' must be an object")
            sys.exit(1)

        version = config.get("version", "")
        features = config.get("features", [])

        if not features:
            print(f"[wings-accel] No features requested for engine '{engine}', skipping")
            continue

        # Validate against supported_features.json if available
        if supported:
            engine_supported = supported.get(engine, {})
            version_supported = engine_supported.get(version, [])
            if version_supported:
                unsupported = [f for f in features if f not in version_supported]
                if unsupported:
                    print(
                        f"[wings-accel] WARNING: features {unsupported} not declared "
                        f"in supported_features.json for {engine} {version}"
                    )

        print(f"[wings-accel] Engine: {engine}, Version: {version}, Features: {features}")
        _install_whls(features)


if __name__ == "__main__":
    main()
