from __future__ import annotations

import re
from pathlib import Path

"""
Basically helps retrieve the ps1 modules in this shared folder to the generator scripts.
The generators reference this file, and this file references the ps1 modules.

Searches for the placeholder {{POWERSHELL_TOOLS: x,y,z}} and replaces each directive with
"""

PARTIAL_TOKEN = "# {{COMMON_POWERSHELL_UI}}"
TOOLS_DIRECTIVE_PATTERN = re.compile(
    r"(?m)^[ \t]*# \{\{POWERSHELL_TOOLS:\s*(?P<tools>[^}]+?)\s*\}\}[ \t]*$"
)

TOOL_FILES = {
    "ConsoleUi": "powershell_ui.ps1",
    "ActiveDirectoryHelpers": "active_directory_helpers.ps1",
    "PowerShellModuleInstall": "powershell_modules.ps1",
    "LicenseHelpers": "license_helpers.ps1",
    "MgGraphHelpers": "mg_graph_helpers.ps1",
    "ExchangeHelpers": "exchange_helpers.ps1"
}

TOOL_DEPENDENCIES = {
    "ActiveDirectoryHelpers": ("ConsoleUi", "PowerShellModuleInstall",),
    "PowerShellModuleInstall": ("ConsoleUi",),
    "MgGraphHelpers": ("ConsoleUi", "PowerShellModuleInstall",),
    "LicenseHelpers": ("ConsoleUi", "MgGraphHelpers",),
    "ExchangeHelpers": ("ConsoleUi", "MgGraphHelpers",)
}


def resolve_common_ui_partial_path(app_dir: Path) -> Path:
    return resolve_tool_partial_path("ConsoleUi", app_dir)


def resolve_tool_partial_path(tool_name: str, app_dir: Path) -> Path:
    try:
        file_name = TOOL_FILES[tool_name]
    except KeyError as exc:
        valid_tools = ", ".join(sorted(TOOL_FILES))
        raise ValueError(f"Unknown PowerShell tool '{tool_name}'. Valid tools: {valid_tools}") from exc

    candidates = [app_dir / "script_builders" / "shared" / file_name, Path(__file__).resolve().parent / file_name]

    for candidate in candidates:
        if candidate.exists():
            return candidate

    return candidates[0]


def parse_tools_directive(value: str) -> list[str]:
    tools: list[str] = []
    seen: set[str] = set()
    for tool in re.split(r"[,;\s]+", value):
        cleaned = tool.strip()
        if not cleaned:
            continue
        if cleaned not in TOOL_FILES:
            valid_tools = ", ".join(sorted(TOOL_FILES))
            raise ValueError(f"Unknown PowerShell tool '{cleaned}'. Valid tools: {valid_tools}")
        if cleaned in seen:
            continue
        seen.add(cleaned)
        tools.append(cleaned)
    return tools


def expand_tool_names(tool_names: list[str]) -> list[str]:
    expanded: list[str] = []
    seen: set[str] = set()

    def visit(tool_name: str) -> None:
        if tool_name in seen:
            return
        for dependency in TOOL_DEPENDENCIES.get(tool_name, ()):
            visit(dependency)
        seen.add(tool_name)
        expanded.append(tool_name)

    for tool_name in tool_names:
        visit(tool_name)
    return expanded


def read_tool_partial(tool_name: str, app_dir: Path) -> str:
    partial_path = resolve_tool_partial_path(tool_name, app_dir)
    if not partial_path.exists():
        raise FileNotFoundError(f"Shared PowerShell tool partial was not found: {partial_path}")
    return partial_path.read_text(encoding="utf-8-sig").strip()


def inline_powershell_tools(template: str, app_dir: Path) -> str:
    inlined_tools: set[str] = set()

    def replace_directive(match: re.Match[str]) -> str:
        requested_tools = parse_tools_directive(match.group("tools"))
        partials = []
        for tool_name in expand_tool_names(requested_tools):
            if tool_name in inlined_tools:
                continue
            inlined_tools.add(tool_name)
            partials.append(read_tool_partial(tool_name, app_dir))
        return "\r\n\r\n".join(partials)

    template = TOOLS_DIRECTIVE_PATTERN.sub(replace_directive, template)
    return inline_common_powershell_ui(template, app_dir)


def inline_common_powershell_ui(template: str, app_dir: Path) -> str:
    if PARTIAL_TOKEN not in template:
        return template

    partial_path = resolve_common_ui_partial_path(app_dir)
    if not partial_path.exists():
        raise FileNotFoundError(f"Shared PowerShell UI partial was not found: {partial_path}")

    partial = partial_path.read_text(encoding="utf-8-sig").strip()
    return template.replace(PARTIAL_TOKEN, partial, 1)
