from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .constants import (
    DEFAULT_SELECTED_PASSWORDS,
    NO_TASK_LINK_OPTION,
    PASSWORD_DISPLAY_PRIORITY,
    PASSWORD_URL_KEY_PREFIX,
)
from .security import is_safe_path_token
from .templates import render_template


def format_password_label(slug: str) -> str:
    special = {
        "primary_admin": "Primary Admin",
        "primaryadmin": "Primary Admin",
        "office365": "Office365",
        "o365": "Office365",
        "m365": "M365",
        "duo": "DUO",
    }
    lowered = slug.lower()
    if lowered in special:
        return special[lowered]
    return slug.replace("_", " ").title()


def is_default_selected_password_slug(slug: str) -> bool:
    normalized = "".join(ch for ch in slug.lower() if ch.isalnum())
    return normalized in DEFAULT_SELECTED_PASSWORDS


def extract_password_entries(values: dict[str, Any]) -> list[dict[str, str]]:
    output: list[dict[str, str]] = []

    for key, raw_value in values.items():
        if not isinstance(key, str):
            continue
        if not key.startswith(PASSWORD_URL_KEY_PREFIX) or not key.endswith("_url"):
            continue
        url = str(raw_value).strip()
        if not url:
            continue
        slug = key[len(PASSWORD_URL_KEY_PREFIX) : -len("_url")]
        output.append(
            {
                "key": key,
                "slug": slug,
                "label": format_password_label(slug),
                "url": url,
                "kind": "password",
            }
        )

    def sort_key(entry: dict[str, str]) -> tuple[int, str]:
        normalized = "".join(ch for ch in entry["slug"].lower() if ch.isalnum())
        priority = PASSWORD_DISPLAY_PRIORITY.get(normalized, 50)
        return priority, entry["label"].lower()

    return sorted(output, key=sort_key)


def normalize_extra_links(
    raw_links: Any,
    resolve_task_id: Callable[[str], str],
) -> list[dict[str, str]]:
    if isinstance(raw_links, dict):
        raw_links = [{"label": str(key), "value": str(value)} for key, value in raw_links.items()]
    if not isinstance(raw_links, list):
        return []

    output: list[dict[str, str]] = []
    index_by_key: dict[tuple[str, str], int] = {}
    for item in raw_links:
        if not isinstance(item, dict):
            continue

        label = str(item.get("label", item.get("key", ""))).strip()
        value = str(item.get("value", "")).strip()
        raw_task = str(item.get("task_id", "")).strip()
        if not raw_task:
            raw_task = str(item.get("task_name", "")).strip()
        if not raw_task:
            raw_task = str(item.get("task", "")).strip()
        task_id = ""
        if raw_task and raw_task != NO_TASK_LINK_OPTION:
            task_id = resolve_task_id(raw_task)

        if not label or not value:
            continue

        dedupe_key = (label.casefold(), task_id.casefold())
        entry = {"label": label, "value": value, "task_id": task_id}
        existing_index = index_by_key.get(dedupe_key)
        if existing_index is None:
            index_by_key[dedupe_key] = len(output)
            output.append(entry)
        else:
            output[existing_index] = entry
    return output


def resolve_extra_link_value(
    value: str,
    values: dict[str, Any],
    validate_launch_url: Callable[[str], tuple[bool, str]],
) -> str:
    cleaned = value.strip()
    if not cleaned:
        return ""
    url_ok, _ = validate_launch_url(cleaned)
    if url_ok:
        return cleaned

    base_url = str(values.get("itglue_base_url", "")).rstrip("/")
    itglue_org_id = str(values.get("itglue_org_id", "")).strip()
    org_id_safe = is_safe_path_token(itglue_org_id)
    if not (base_url and org_id_safe):
        return ""

    password_id = cleaned.strip("/")
    if not password_id or "/" in password_id:
        return ""
    if any(ch.isspace() for ch in password_id):
        return ""
    if not is_safe_path_token(password_id):
        return ""

    candidate = f"{base_url}/{itglue_org_id}/passwords/{password_id}"
    candidate_ok, _ = validate_launch_url(candidate)
    return candidate if candidate_ok else ""


def extract_extra_checklist_entries(
    values: dict[str, Any],
    normalized_extra_links: list[dict[str, str]],
    resolve_value: Callable[[str], str],
) -> list[dict[str, str]]:
    output: list[dict[str, str]] = []
    for entry in normalized_extra_links:
        task_id = str(entry.get("task_id", "")).strip()
        if task_id:
            continue

        template = str(entry.get("value", "")).strip()
        rendered, missing = render_template(template, values)
        if missing:
            continue
        url = resolve_value(rendered)
        if not url:
            continue

        label = str(entry.get("label", "")).strip()
        if not label:
            continue

        stable_key = label.casefold()
        output.append(
            {
                "key": f"extra_link::{stable_key}",
                "slug": "",
                "label": label,
                "url": url,
                "kind": "extra",
            }
        )
    return sorted(output, key=lambda item: item["label"].lower())


def extract_task_extra_link_entries(
    values: dict[str, Any],
    task_id: str,
    normalized_extra_links: list[dict[str, str]],
    resolve_value: Callable[[str], str],
) -> list[dict[str, str | bool]]:
    cleaned_task_id = task_id.strip()
    if not cleaned_task_id:
        return []

    output: list[dict[str, str | bool]] = []
    for entry in normalized_extra_links:
        entry_task_id = str(entry.get("task_id", "")).strip()
        if not entry_task_id or entry_task_id.casefold() != cleaned_task_id.casefold():
            continue

        label = str(entry.get("label", "")).strip() or "Extra Link"
        template = str(entry.get("value", "")).strip()
        rendered, missing = render_template(template, values)
        if missing:
            output.append(
                {
                    "label": label,
                    "url": rendered,
                    "valid": False,
                }
            )
            continue

        resolved_url = resolve_value(rendered)
        valid = bool(resolved_url)
        output.append(
            {
                "label": label,
                "url": resolved_url if valid else rendered,
                "valid": valid,
            }
        )
    return output


def build_task_links(
    task: dict[str, Any],
    values: dict[str, Any],
    validate_launch_url: Callable[[str], tuple[bool, str]],
    task_extra_entries: list[dict[str, str | bool]],
) -> list[dict[str, str | bool]]:
    output: list[dict[str, str | bool]] = []

    for link in task.get("links", []):
        label = str(link.get("label", "Unnamed link"))
        template = str(link.get("template", "")).strip()
        optional = bool(link.get("optional", False))
        if not template:
            if optional:
                continue
            output.append({"label": label, "url": "", "valid": False})
            continue

        rendered, missing = render_template(template, values)
        if missing:
            if optional:
                continue
            output.append(
                {
                    "label": label,
                    "url": rendered,
                    "valid": False,
                }
            )
            continue

        valid, _ = validate_launch_url(rendered)
        if optional and not valid:
            continue
        output.append(
            {
                "label": label,
                "url": rendered,
                "valid": valid,
            }
        )

    output.extend(task_extra_entries)
    return output
