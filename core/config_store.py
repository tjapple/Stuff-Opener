from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

from .constants import DEFAULT_CONFIG_FILENAMES
from .paths import APP_DIR, user_data_dir_candidates


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"Missing config file: {path}")

    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    if "tasks" not in data or not isinstance(data["tasks"], list):
        raise ValueError("Config must include a 'tasks' list.")
    if "clients" not in data or not isinstance(data["clients"], list):
        raise ValueError("Config must include a 'clients' list.")

    return data


def save_config(path: Path, config: dict[str, Any]) -> None:
    path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def ensure_runtime_config(app_dir: Path = APP_DIR) -> Path:
    default_config_sources = [app_dir / name for name in DEFAULT_CONFIG_FILENAMES if (app_dir / name).exists()]
    if not default_config_sources:
        raise FileNotFoundError(
            "No default config was found. Expected one of: "
            + ", ".join(str(app_dir / name) for name in DEFAULT_CONFIG_FILENAMES)
        )

    errors: list[str] = []
    for user_data_dir in user_data_dir_candidates(app_dir):
        runtime_path = user_data_dir / "config.json"
        try:
            user_data_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            errors.append(f"{user_data_dir} (mkdir failed: {exc})")
            continue

        if runtime_path.exists():
            return runtime_path

        for source in default_config_sources:
            try:
                shutil.copy2(source, runtime_path)
                return runtime_path
            except OSError as exc:
                errors.append(f"{runtime_path} (copy failed from {source}: {exc})")

    raise PermissionError(
        "Could not create runtime config in any candidate directory.\n"
        + "\n".join(f"- {entry}" for entry in errors)
    )
