from __future__ import annotations

import ctypes
import os
import threading
import time
from pathlib import Path
from typing import Any

import webview

from .api import StuffOpenerWebApi


class StuffOpenerWebApp:
    def __init__(self, *, config_path: Path, app_dir: Path) -> None:
        self.app_dir = app_dir
        self.api = StuffOpenerWebApi(config_path=config_path, app_dir=app_dir)
        self.window: Any = None
        self._window_icon_handles: list[int] = []
        self._window_icon_refs: list[Any] = []

    def html_path(self) -> Path:
        candidates = [
            self.app_dir / "ui_web" / "web" / "index.html",
            Path(__file__).resolve().parent / "web" / "index.html",
        ]

        for candidate in candidates:
            if candidate.exists():
                return candidate

        return candidates[0]

    def create_window(self) -> Any:
        html_path = self.html_path()
        self.window = webview.create_window(
            "Stuff Opener",
            html_path.as_uri(),
            js_api=self.api,
            width=1280,
            height=820,
            min_size=(1080, 680),
        )
        self.api.set_window(self.window)
        self.window.events.shown += self._schedule_window_icon
        return self.window

    def focus_window(self) -> None:
        self.api.focus_window()

    def start(self) -> None:
        self.create_window()
        webview.start(debug=False)

    def _schedule_window_icon(self) -> None:
        if os.name != "nt" or self.window is None:
            return

        threading.Thread(target=self._apply_window_icon, daemon=True).start()

    def _apply_window_icon(self) -> None:
        icon_path = self.app_dir / "logo_new.ico"
        if not icon_path.exists():
            return

        native = None
        handle = None
        for _ in range(20):
            native = getattr(self.window, "native", None)
            handle = getattr(native, "Handle", None) if native is not None else None
            if handle is not None:
                break
            time.sleep(0.1)

        if handle is None or native is None:
            return

        try:
            import clr

            clr.AddReference("System.Drawing")
            import System.Drawing as SD  # type: ignore

            icon = SD.Icon(str(icon_path))
            native.Icon = icon
            self._window_icon_refs.append(icon)
        except Exception:
            pass

        try:
            hwnd = int(handle.ToInt64())
        except Exception:
            try:
                hwnd = int(handle.ToInt32())
            except Exception:
                return

        user32 = ctypes.windll.user32
        user32.LoadImageW.argtypes = [
            ctypes.c_void_p,
            ctypes.c_wchar_p,
            ctypes.c_uint,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint,
        ]
        user32.LoadImageW.restype = ctypes.c_void_p
        user32.SendMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_void_p]
        user32.SendMessageW.restype = ctypes.c_void_p
        image_icon = 1
        load_from_file = 0x0010
        wm_seticon = 0x0080
        icon_small = 0
        icon_big = 1
        icon_small2 = 2

        def load_icon(size: int) -> int:
            handle_value = user32.LoadImageW(
                None,
                str(icon_path),
                image_icon,
                size,
                size,
                load_from_file,
            )
            return int(handle_value or 0)

        big_icon = load_icon(32)
        small_icon = load_icon(16)
        if big_icon:
            user32.SendMessageW(ctypes.c_void_p(hwnd), wm_seticon, icon_big, ctypes.c_void_p(big_icon))
            self._window_icon_handles.append(big_icon)
        if small_icon:
            user32.SendMessageW(ctypes.c_void_p(hwnd), wm_seticon, icon_small, ctypes.c_void_p(small_icon))
            user32.SendMessageW(ctypes.c_void_p(hwnd), wm_seticon, icon_small2, ctypes.c_void_p(small_icon))
            self._window_icon_handles.append(small_icon)
