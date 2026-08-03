from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlparse

from .constants import ALLOWED_URL_SCHEMES, DEFAULT_ALLOWED_HOST_SUFFIXES


def is_supported_url(url: str, allowed_schemes: set[str] = ALLOWED_URL_SCHEMES) -> bool:
    parsed = urlparse(url.strip())
    return parsed.scheme.lower() in allowed_schemes and bool(parsed.netloc)


def normalize_host_suffix(raw_value: str) -> str:
    cleaned = raw_value.strip().lower()
    if not cleaned:
        return ""
    if "://" in cleaned:
        parsed = urlparse(cleaned)
        host = (parsed.hostname or "").strip().lower()
        return host.strip(".")
    return cleaned.lstrip(".")


def is_safe_path_token(value: str) -> bool:
    return re.fullmatch(r"[A-Za-z0-9_-]+", value.strip()) is not None


def load_allowed_host_suffixes(config: dict[str, Any]) -> tuple[str, ...]:
    configured_suffixes: list[str] = []
    security = config.get("security", {})
    if isinstance(security, dict):
        raw_suffixes = security.get("allowed_host_suffixes", [])
        if isinstance(raw_suffixes, list):
            for item in raw_suffixes:
                if not isinstance(item, str):
                    continue
                normalized = normalize_host_suffix(item)
                if normalized:
                    configured_suffixes.append(normalized)

    effective = configured_suffixes if configured_suffixes else list(DEFAULT_ALLOWED_HOST_SUFFIXES)
    return tuple(dict.fromkeys(effective))


def is_allowed_host(hostname: str, allowed_host_suffixes: tuple[str, ...]) -> bool:
    host = hostname.strip().lower().strip(".")
    if not host:
        return False

    for suffix in allowed_host_suffixes:
        normalized_suffix = normalize_host_suffix(suffix)
        if not normalized_suffix:
            continue
        if host == normalized_suffix or host.endswith(f".{normalized_suffix}"):
            return True
    return False


def validate_launch_url(url: str, allowed_host_suffixes: tuple[str, ...]) -> tuple[bool, str]:
    cleaned = url.strip()
    if not cleaned:
        return False, "INVALID_URL"
    if not is_supported_url(cleaned):
        return False, "BLOCKED_SCHEME"

    parsed = urlparse(cleaned)
    host = (parsed.hostname or "").strip().lower()
    if not host:
        return False, "INVALID_URL"
    if not is_allowed_host(host, allowed_host_suffixes):
        return False, "BLOCKED_HOST"
    return True, "READY"
