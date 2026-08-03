from __future__ import annotations

import re
import string
from typing import Any


def slugify_name(name: str) -> str:
    lowered = name.strip().lower()
    cleaned = re.sub(r"[^a-z0-9]+", "_", lowered)
    return cleaned.strip("_")


def extract_template_fields(template: str) -> list[str]:
    fields: list[str] = []
    for _, field_name, _, _ in string.Formatter().parse(template):
        if field_name and field_name not in fields:
            fields.append(field_name)
    return fields


def render_template(template: str, values: dict[str, Any]) -> tuple[str, list[str]]:
    try:
        fields = extract_template_fields(template)
    except ValueError as exc:
        return template, [f"template syntax error: {exc}"]

    missing = [field for field in fields if not values.get(field)]
    if missing:
        return template, missing

    try:
        return template.format(**values), []
    except (IndexError, KeyError, AttributeError, ValueError) as exc:
        return template, [f"template render error: {exc}"]
