from __future__ import annotations

import socket
import threading
from collections.abc import Callable

from .constants import INSTANCE_HOST, INSTANCE_PORT


def send_focus_request() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.01)
    try:
        if sock.connect_ex((INSTANCE_HOST, INSTANCE_PORT)) != 0:
            return False
        sock.sendall(b"FOCUS")
        return True
    except OSError:
        return False
    finally:
        try:
            sock.close()
        except OSError:
            pass


class SingleInstanceServer:
    def __init__(self, focus_callback: Callable[[], None]) -> None:
        self.focus_callback = focus_callback
        self.stop_event = threading.Event()
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((INSTANCE_HOST, INSTANCE_PORT))
        self.server.listen(5)
        self.server.settimeout(0.5)

        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        while not self.stop_event.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break

            try:
                with conn:
                    data = conn.recv(64)
                if data.startswith(b"FOCUS"):
                    self.focus_callback()
            except OSError:
                continue

    def close(self) -> None:
        self.stop_event.set()
        try:
            self.server.close()
        except OSError:
            pass
