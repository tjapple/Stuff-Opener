from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import urlsplit

from core.config_store import ensure_runtime_config, load_config
from core.links import format_password_label, is_default_selected_password_slug


PROJECT_ROOT = Path(__file__).resolve().parent.parent
EXAMPLE_CONFIG = PROJECT_ROOT / "config.example.json"


def iter_strings(value: object):
    if isinstance(value, dict):
        for child in value.values():
            yield from iter_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_strings(child)
    elif isinstance(value, str):
        yield value


class PublicConfigTests(unittest.TestCase):
    def test_example_config_loads(self) -> None:
        config = load_config(EXAMPLE_CONFIG)
        self.assertGreaterEqual(len(config["tasks"]), 1)
        self.assertGreaterEqual(len(config["clients"]), 1)

    def test_example_config_is_valid_json_with_terminal_newline(self) -> None:
        raw = EXAMPLE_CONFIG.read_text(encoding="utf-8")
        self.assertTrue(raw.endswith("\n"))
        json.loads(raw)

    def test_example_urls_use_only_documented_demo_or_vendor_hosts(self) -> None:
        config = load_config(EXAMPLE_CONFIG)
        allowed_hosts = {"example.com", "admin.duosecurity.com"}
        urls = [value for value in iter_strings(config) if value.startswith("https://")]
        self.assertTrue(urls)
        for url in urls:
            with self.subTest(url=url):
                self.assertIn(urlsplit(url).hostname, allowed_hosts)

    def test_source_bootstrap_uses_example_config_when_no_private_seed_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            with patch.dict(os.environ, {"LOCALAPPDATA": temp_dir}):
                runtime_path = ensure_runtime_config(PROJECT_ROOT)

            runtime_config = load_config(runtime_path)
            self.assertEqual(runtime_path.parent, Path(temp_dir) / "StuffOpener")
            self.assertEqual(runtime_config["clients"][0]["name"], "Example Manufacturing")

    def test_generic_primary_admin_password_label_and_default(self) -> None:
        self.assertEqual(format_password_label("primary_admin"), "Primary Admin")
        self.assertTrue(is_default_selected_password_slug("primary_admin"))


if __name__ == "__main__":
    unittest.main()
