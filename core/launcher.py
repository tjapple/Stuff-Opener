from __future__ import annotations

import ctypes
import os
import subprocess
import sys
import webbrowser
from pathlib import Path

from .constants import WINDOWS_APP_ID


def set_windows_app_id() -> None:
    if not hasattr(ctypes, "windll"):
        return
    try:
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(WINDOWS_APP_ID)
    except Exception:
        pass


def windows_creationflags() -> int:
    if os.name != "nt":
        return 0
    return int(getattr(subprocess, "CREATE_NO_WINDOW", 0))


def open_urls(urls: list[str]) -> None:
    for url in urls:
        webbrowser.open_new_tab(url)


def open_path_in_default_app(path: Path) -> None:
    target = str(path)
    if os.name == "nt" and hasattr(os, "startfile"):
        try:
            os.startfile(target)  # type: ignore[attr-defined]
        except OSError:
            if path.is_file():
                try:
                    subprocess.Popen(["notepad.exe", target])
                    return
                except OSError:
                    pass
            folder_target = str(path.parent if path.is_file() else path)
            subprocess.Popen(["explorer.exe", folder_target])
        return
    if sys.platform == "darwin":
        subprocess.Popen(["open", target])
        return
    subprocess.Popen(["xdg-open", target])
