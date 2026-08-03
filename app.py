from __future__ import annotations

import sys

import webview

from core.config_store import ensure_runtime_config
from core.launcher import set_windows_app_id
from core.paths import APP_DIR
from core.single_instance import SingleInstanceServer, send_focus_request
from ui_web.app_window import StuffOpenerWebApp


def _show_startup_error(message: str) -> None:
    try:
        webview.create_window("Stuff Opener startup error", html=f"<pre>{message}</pre>", width=720, height=320)
        webview.start()
    except Exception:
        print(message, file=sys.stderr)


def main() -> None:
    if send_focus_request():
        return

    set_windows_app_id()

    try:
        runtime_config_path = ensure_runtime_config()
    except Exception as exc:  # pylint: disable=broad-except
        _show_startup_error(f"Could not prepare runtime config.\n\n{exc}")
        return

    app = StuffOpenerWebApp(config_path=runtime_config_path, app_dir=APP_DIR)
    app.create_window()

    try:
        instance_server = SingleInstanceServer(app.focus_window)
    except OSError:
        send_focus_request()
        return

    try:
        webview.start(debug=False, gui="edgechromium")
    except Exception as exc:  # pylint: disable=broad-except
        message = str(exc)
        if "edgechromium" in message.lower() or "webview2" in message.lower() or "edge chromium" in message.lower():
            message = (
                "Stuff Opener requires the Microsoft Edge WebView2 runtime on this machine.\n\n"
                f"{exc}\n\n"
                "Install WebView2 Runtime, then launch Stuff Opener again."
            )
        _show_startup_error(message)
    finally:
        instance_server.close()


if __name__ == "__main__":
    main()
