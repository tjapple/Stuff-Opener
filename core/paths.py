from __future__ import annotations

import os
import sys
from pathlib import Path

from .constants import APP_NAME


def resolve_app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


APP_DIR = resolve_app_dir()


def user_data_dir_candidates(app_dir: Path = APP_DIR) -> list[Path]:
    candidates: list[Path] = []

    local_app_data = os.environ.get("LOCALAPPDATA", "").strip()
    if local_app_data:
        candidates.append(Path(local_app_data) / APP_NAME)

    candidates.append(Path.home() / f".{APP_NAME.lower()}")
    candidates.append(app_dir / ".runtime")

    unique: list[Path] = []
    seen: set[str] = set()
    for path in candidates:
        key = str(path).lower()
        if key in seen:
            continue
        seen.add(key)
        unique.append(path)
    return unique
