from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

import webview

from core.client_tasks import build_client_task_state, resolve_casefold_name
from core.config_store import load_config, save_config
from core.constants import (
    DEFAULT_TASK_SCRIPT_BUILDERS,
    EXTRA_LINKS_KEY,
    HOTKEY_HELPER_EXE_NAME,
    HOTKEY_SCRIPT_NAME,
    NO_TASK_LINK_OPTION,
    UI_CONFIG_KEY,
    UI_THEME_CONFIG_KEY,
)
from core.launcher import open_path_in_default_app, open_urls, windows_creationflags
from core.links import (
    build_task_links,
    extract_extra_checklist_entries,
    extract_password_entries,
    extract_task_extra_link_entries,
    is_default_selected_password_slug,
    normalize_extra_links,
    resolve_extra_link_value,
)
from core.security import is_safe_path_token, load_allowed_host_suffixes, validate_launch_url
from core.templates import slugify_name
from script_builders.user_new.generator import (
    new_user_script,
    new_user_script_file_name,
    resolve_template_path as resolve_user_new_template_path,
)
from script_builders.user_lockdown.generator import (
    new_user_lockdown_script,
    new_user_lockdown_script_file_name,
    resolve_template_path as resolve_user_lockdown_template_path,
)
from script_builders.user_term.generator import (
    DEFAULT_GROUPS_TO_REMOVE,
    new_termination_script,
    new_termination_script_file_name,
    resolve_template_path as resolve_user_term_template_path,
    split_ui_list,
)


WEB_THEMES = ("command", "midnight", "ember", "aurora", "matrix", "violet", "steel", "rose")
WEB_STYLES = ("standard", "compact", "soft", "squared")
UI_STYLE_CONFIG_KEY = "style"


class StuffOpenerWebApi:
    def __init__(self, *, config_path: Path, app_dir: Path) -> None:
        self.config_path = config_path
        self.app_dir = app_dir
        self.window: Any = None
        self.current_scripts: dict[str, str] = {}
        self._load_runtime_config()

    def set_window(self, window: Any) -> None:
        self.window = window

    def load_initial_state(self) -> dict[str, Any]:
        client_name = self.client_name_options[0] if self.client_name_options else ""
        task_name = ""
        return {
            "clients": self.client_name_options,
            "tasks": self.task_name_options,
            "selectedClient": client_name,
            "selectedTask": task_name,
            "launcher": self._launcher_payload(client_name, task_name),
            "clientForm": self._client_form_payload(client_name),
            "scriptBuilders": self._script_builder_options(),
            "builder": self._builder_payload("user_term", client_name),
            "theme": self._current_theme(),
            "style": self._current_style(),
            "hotkey": self._hotkey_payload(),
            "status": "Select a client. Task is optional.",
            "log": ["Loaded Stuff Opener WebView frontend."],
        }

    def select_client(self, client_name: str, task_name: str = "") -> dict[str, Any]:
        canonical_client = self._resolve_client_name(client_name) or client_name.strip()
        canonical_task = self._resolve_task_name(task_name) or task_name.strip()
        return {
            "selectedClient": canonical_client,
            "selectedTask": canonical_task,
            "launcher": self._launcher_payload(canonical_client, canonical_task),
            "clientForm": self._client_form_payload(canonical_client),
            "builder": self._builder_payload("user_term", canonical_client),
            "status": self._selection_status(canonical_client, canonical_task),
        }

    def select_task(self, client_name: str, task_name: str) -> dict[str, Any]:
        canonical_client = self._resolve_client_name(client_name) or client_name.strip()
        canonical_task = self._resolve_task_name(task_name) or task_name.strip()
        return {
            "selectedClient": canonical_client,
            "selectedTask": canonical_task,
            "launcher": self._launcher_payload(canonical_client, canonical_task),
            "openBuilder": self._get_task_script_builder_id(self.task_map.get(canonical_task)),
            "status": self._selection_status(canonical_client, canonical_task),
        }

    def launch_all(self, client_name: str, task_name: str, selected_keys: list[str]) -> dict[str, Any]:
        client, task = self._selected(client_name, task_name)
        if client is None:
            return self._error("Select a client before launching.")

        links = self._links_for(client, task)
        base_urls = [str(link["url"]) for link in links if bool(link["valid"])]
        selected_urls = self._password_urls_for(client, task, selected_keys)
        urls = list(dict.fromkeys([url for url in [*base_urls, *selected_urls] if url]))
        if not urls:
            return self._error("No valid links are ready to open.")

        open_urls(urls)
        skipped = len(links) - len(base_urls)
        message = f"Launched {len(urls)} tab(s)."
        if skipped:
            message = f"{message} Skipped {skipped} invalid workflow link(s)."
        self._focus_window()
        return {
            "ok": True,
            "status": message,
            "openBuilder": self._get_task_script_builder_id(task),
        }

    def launch_selected(self, client_name: str, selected_keys: list[str]) -> dict[str, Any]:
        client, _ = self._selected(client_name, "")
        if client is None:
            return self._error("Select a client before launching selected items.")
        urls = self._password_urls_for(client, None, selected_keys)
        if not urls:
            return self._error("Select at least one item in Passwords and extra links.")
        open_urls(urls)
        return {"ok": True, "status": f"Launched {len(urls)} selected item(s)."}

    def open_link(self, url: str) -> dict[str, Any]:
        valid, reason = self._validate_launch_url(url)
        if not valid:
            return self._error(f"Blocked link: {reason}")
        open_urls([url])
        return {"ok": True, "status": "Opened selected link in browser."}

    def open_config(self) -> dict[str, Any]:
        open_path_in_default_app(self.config_path)
        return {"ok": True, "status": f"Opened config: {self.config_path}"}

    def open_template(self, builder_id: str) -> dict[str, Any]:
        path = self._template_path(builder_id)
        if not path.exists():
            return self._error(f"Template was not found: {path}")
        open_path_in_default_app(path)
        return {"ok": True, "status": f"Opened template: {path}"}

    def save_client(self, payload: dict[str, Any]) -> dict[str, Any]:
        client, missing = self._client_from_payload(payload)
        if missing:
            return self._error("Missing required fields: " + ", ".join(missing))

        clients = self.config.get("clients", [])
        if not isinstance(clients, list):
            clients = []
            self.config["clients"] = clients

        new_id = str(client["id"]).casefold()
        new_name = str(client["name"]).casefold()
        loaded_id = str(payload.get("loadedId", "")).casefold()
        existing_index: int | None = None
        for index, existing in enumerate(clients):
            existing_id = str(existing.get("id", "")).casefold()
            existing_name = str(existing.get("name", "")).casefold()
            if loaded_id and existing_id == loaded_id:
                existing_index = index
                break
            if existing_id == new_id or existing_name == new_name:
                existing_index = index
                break

        action = "added"
        if existing_index is None:
            clients.append(client)
        else:
            clients[existing_index] = client
            action = "updated"
        clients.sort(key=lambda item: str(item.get("name", "")).casefold())
        self.config["clients"] = clients
        self._save_runtime_config()
        self._load_runtime_config()

        client_name = str(client["name"])
        return {
            "ok": True,
            "status": f"Client {action}: {client_name}",
            "clients": self.client_name_options,
            "selectedClient": client_name,
            "launcher": self._launcher_payload(client_name, ""),
            "clientForm": self._client_form_payload(client_name),
            "builder": self._builder_payload("user_term", client_name),
        }

    def builder_context(self, builder_id: str, client_name: str = "") -> dict[str, Any]:
        return {"builder": self._builder_payload(builder_id, client_name)}

    def focus_window(self) -> dict[str, Any]:
        self._focus_window()
        return {"ok": True}

    def generate_script(self, builder_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        try:
            script = self._generate_script(builder_id, payload)
        except Exception as exc:  # pylint: disable=broad-except
            return self._error(str(exc))
        self.current_scripts[builder_id] = script
        return {
            "ok": True,
            "script": script,
            "status": f"{self._builder_label(builder_id)} script preview generated.",
        }

    def save_script(self, builder_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        try:
            script = self.current_scripts.get(builder_id) or self._generate_script(builder_id, payload)
            file_name = self._script_file_name(builder_id, payload)
        except Exception as exc:  # pylint: disable=broad-except
            return self._error(str(exc))

        output_path = self._choose_save_path(file_name)
        if not output_path:
            return {"ok": False, "status": "Save cancelled."}
        try:
            Path(output_path).write_text(script, encoding="utf-8")
        except OSError as exc:
            return self._error(f"Could not save script: {exc}")
        self.current_scripts[builder_id] = script
        return {"ok": True, "status": f"Saved script: {output_path}"}

    def set_theme(self, theme: str) -> dict[str, Any]:
        cleaned = theme if theme in WEB_THEMES else WEB_THEMES[0]
        ui_config = self.config.setdefault(UI_CONFIG_KEY, {})
        if isinstance(ui_config, dict):
            ui_config[UI_THEME_CONFIG_KEY] = cleaned
            self._save_runtime_config()
        return {"ok": True, "theme": cleaned}

    def set_style(self, style: str) -> dict[str, Any]:
        cleaned = style if style in WEB_STYLES else WEB_STYLES[0]
        ui_config = self.config.setdefault(UI_CONFIG_KEY, {})
        if isinstance(ui_config, dict):
            ui_config[UI_STYLE_CONFIG_KEY] = cleaned
            self._save_runtime_config()
        return {"ok": True, "style": cleaned}

    def hotkey_status(self) -> dict[str, Any]:
        return self._hotkey_payload()

    def enable_hotkey(self) -> dict[str, Any]:
        if self._is_hotkey_helper_running():
            return {"ok": True, "hotkey": self._hotkey_payload(), "status": "hotkey enabled (alt + O/C)"}
        ok, message = self._start_hotkey_helper()
        if not ok:
            return self._error(message)
        return {"ok": True, "hotkey": self._hotkey_payload(), "status": "Starting hotkey helper (alt + O/C)..."}

    def _load_runtime_config(self) -> None:
        self.config = load_config(self.config_path)
        state = build_client_task_state(self.config)
        self.clients = state["clients"]
        self.tasks = state["tasks"]
        self.client_name_options = state["client_name_options"]
        self.client_map = state["client_map"]
        self.client_casefold_map = state["client_casefold_map"]
        self.task_name_options = state["task_name_options"]
        self.task_map = state["task_map"]
        self.task_casefold_map = state["task_casefold_map"]
        self.task_id_map = state["task_id_map"]
        self.allowed_host_suffixes = load_allowed_host_suffixes(self.config)

    def _save_runtime_config(self) -> None:
        save_config(self.config_path, self.config)

    def _current_theme(self) -> str:
        ui_config = self.config.get(UI_CONFIG_KEY, {})
        if isinstance(ui_config, dict):
            theme = str(ui_config.get(UI_THEME_CONFIG_KEY, WEB_THEMES[0]))
            if theme in WEB_THEMES:
                return theme
        return WEB_THEMES[0]

    def _current_style(self) -> str:
        ui_config = self.config.get(UI_CONFIG_KEY, {})
        if isinstance(ui_config, dict):
            style = str(ui_config.get(UI_STYLE_CONFIG_KEY, WEB_STYLES[0]))
            if style in WEB_STYLES:
                return style
        return WEB_STYLES[0]

    def _resolve_client_name(self, typed_name: str) -> str | None:
        return resolve_casefold_name(typed_name, self.client_casefold_map)

    def _resolve_task_name(self, typed_name: str) -> str | None:
        return resolve_casefold_name(typed_name, self.task_casefold_map)

    def _selected(self, client_name: str, task_name: str) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        client = self.client_map.get(self._resolve_client_name(client_name) or client_name.strip())
        task = self.task_map.get(self._resolve_task_name(task_name) or task_name.strip())
        return client, task

    def _selection_status(self, client_name: str, task_name: str) -> str:
        client, task = self._selected(client_name, task_name)
        if not client:
            return "Select a client."
        links = self._links_for(client, task)
        password_count = len([item for item in self._checklist_for(client, task) if bool(item.get("selected"))])
        if task:
            ready_count = sum(1 for link in links if bool(link.get("valid")))
            return f"Loaded {client_name} / {task_name}: {ready_count} workflow link(s), {password_count} password/extra link(s) selected."
        return f"Loaded {client_name}: {password_count} password/extra link(s) selected. Select a task to add workflow links."

    def _launcher_payload(self, client_name: str, task_name: str) -> dict[str, Any]:
        client, task = self._selected(client_name, task_name)
        if not client:
            return {"links": [], "passwordItems": [], "passwordHeading": "Client Passwords and extra links:"}
        items = self._checklist_for(client, task)
        selected_count = sum(1 for item in items if bool(item.get("selected")))
        return {
            "links": self._links_for(client, task),
            "passwordItems": items,
            "passwordHeading": f"{client.get('name', '')} Passwords and extra links ({selected_count}/{len(items)} selected):",
        }

    def _build_values(self, client: dict[str, Any], task: dict[str, Any] | None = None) -> dict[str, Any]:
        values: dict[str, Any] = {}
        globals_payload = self.config.get("globals", {})
        if isinstance(globals_payload, dict):
            values.update(globals_payload)
        vars_payload = client.get("vars", {})
        if isinstance(vars_payload, dict):
            values.update(vars_payload)
        values["client_name"] = client.get("name", "")
        values["client_id"] = client.get("id", "")
        values["task_name"] = task.get("name", "") if task else ""
        values["task_id"] = task.get("id", "") if task else ""

        base_url = str(values.get("itglue_base_url", "")).rstrip("/")
        itglue_org_id = str(values.get("itglue_org_id", "")).strip()
        org_id_safe = is_safe_path_token(itglue_org_id)
        for key in list(values):
            if not isinstance(key, str):
                continue
            if not key.startswith("itglue_password_") or not key.endswith("_id"):
                continue
            slug = key[len("itglue_password_") : -len("_id")]
            url_key = f"itglue_password_{slug}_url"
            if values.get(url_key):
                continue
            password_id = str(values.get(key, "")).strip()
            if not (base_url and org_id_safe and password_id and is_safe_path_token(password_id)):
                continue
            candidate = f"{base_url}/{itglue_org_id}/passwords/{password_id}"
            valid, _ = self._validate_launch_url(candidate)
            if valid:
                values[url_key] = candidate

        global_links = self._get_global_links()
        for reference_key, url_key in (
            ("new_user_sop_default", "new_user_sop_default_url"),
            ("user_termination_sop", "user_termination_sop_url"),
        ):
            if values.get(url_key):
                continue
            reference = str(values.get(reference_key, "")).strip()
            if not reference:
                continue
            linked = global_links.get(reference, "")
            if linked:
                values[url_key] = linked
                continue
            valid, _ = self._validate_launch_url(reference)
            if valid:
                values[url_key] = reference

        duo_password_id = str(values.get("itglue_password_duo_id", "")).strip()
        if not duo_password_id:
            values["duo_admin_url"] = ""
        elif not values.get("duo_admin_url"):
            candidate = global_links.get("duo_admin_portal") or global_links.get("duo_admin_url")
            if candidate:
                values["duo_admin_url"] = candidate.strip()

        return values

    def _get_global_links(self) -> dict[str, str]:
        links = self.config.get("global_links", {})
        if not isinstance(links, dict):
            return {}
        normalized: dict[str, str] = {}
        for key, value in links.items():
            if not isinstance(value, str):
                continue
            cleaned = value.strip()
            valid, _ = self._validate_launch_url(cleaned)
            if cleaned and valid:
                normalized[str(key)] = cleaned
        return normalized

    def _normalize_extra_links_for(self, values: dict[str, Any]) -> list[dict[str, str]]:
        return normalize_extra_links(values.get(EXTRA_LINKS_KEY, []), self._resolve_task_id)

    def _resolve_extra_value_for(self, values: dict[str, Any], value: str) -> str:
        return resolve_extra_link_value(value, values, self._validate_launch_url)

    def _checklist_for(self, client: dict[str, Any], task: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        values = self._build_values(client, task)
        normalized_extra_links = self._normalize_extra_links_for(values)
        entries = extract_password_entries(values) + extract_extra_checklist_entries(
            values,
            normalized_extra_links,
            lambda value: self._resolve_extra_value_for(values, value),
        )
        output: list[dict[str, Any]] = []
        for entry in entries:
            selected = False
            if entry.get("kind") == "password":
                selected = is_default_selected_password_slug(str(entry.get("slug", "")))
            output.append({**entry, "selected": selected})
        return output

    def _password_urls_for(
        self,
        client: dict[str, Any],
        task: dict[str, Any] | None,
        selected_keys: list[str],
    ) -> list[str]:
        selected = {str(key) for key in selected_keys}
        urls: list[str] = []
        for item in self._checklist_for(client, task):
            if str(item.get("key", "")) not in selected:
                continue
            url = str(item.get("url", "")).strip()
            valid, _ = self._validate_launch_url(url)
            if valid:
                urls.append(url)
        return urls

    def _links_for(self, client: dict[str, Any], task: dict[str, Any] | None) -> list[dict[str, Any]]:
        if not task:
            return []
        values = self._build_values(client, task)
        normalized_extra_links = self._normalize_extra_links_for(values)
        task_extra_entries = extract_task_extra_link_entries(
            values,
            str(task.get("id", "")),
            normalized_extra_links,
            lambda value: self._resolve_extra_value_for(values, value),
        )
        return build_task_links(task, values, self._validate_launch_url, task_extra_entries)

    def _validate_launch_url(self, url: str) -> tuple[bool, str]:
        return validate_launch_url(url, self.allowed_host_suffixes)

    def _resolve_task_id(self, raw_task: str) -> str:
        cleaned = raw_task.strip()
        if not cleaned:
            return ""
        for known_id in self.task_id_map:
            if known_id.casefold() == cleaned.casefold():
                return known_id
        canonical_name = self._resolve_task_name(cleaned)
        if canonical_name:
            task = self.task_map.get(canonical_name, {})
            return str(task.get("id", "")).strip()
        return ""

    def _task_name_from_id(self, task_id: str) -> str:
        cleaned = task_id.strip()
        if not cleaned:
            return NO_TASK_LINK_OPTION
        for known_id, task in self.task_id_map.items():
            if known_id.casefold() == cleaned.casefold():
                return str(task.get("name", "")).strip() or NO_TASK_LINK_OPTION
        return NO_TASK_LINK_OPTION

    def _client_form_payload(self, client_name: str) -> dict[str, Any]:
        client = self.client_map.get(self._resolve_client_name(client_name) or client_name.strip(), {})
        vars_payload = client.get("vars", {}) if isinstance(client, dict) else {}
        if not isinstance(vars_payload, dict):
            vars_payload = {}
        extra_links = []
        for entry in normalize_extra_links(vars_payload.get(EXTRA_LINKS_KEY, []), self._resolve_task_id):
            extra_links.append(
                {
                    "label": entry.get("label", ""),
                    "value": entry.get("value", ""),
                    "taskId": entry.get("task_id", ""),
                    "taskName": self._task_name_from_id(str(entry.get("task_id", ""))),
                }
            )
        name = str(client.get("name", client_name)).strip()
        slug = slugify_name(name)
        return {
            "loadedId": str(client.get("id", "")),
            "name": name,
            "id": slug,
            "slug": slug,
            "itglueOrgId": str(vars_payload.get("itglue_org_id", "")),
            "userCreateTermUrl": str(vars_payload.get("itglue_user_create_term_url", "")),
            "outageHandlingUrl": str(vars_payload.get("itglue_outage_handling_url", "")),
            "primaryAdminPasswordId": str(vars_payload.get("itglue_password_primary_admin_id", "")),
            "office365PasswordId": str(vars_payload.get("itglue_password_office365_id", "")),
            "localAdminPasswordId": str(vars_payload.get("itglue_password_local_admin_id", "")),
            "duoPasswordId": str(vars_payload.get("itglue_password_duo_id", "")),
            "newUserSopKey": str(vars_payload.get("new_user_sop_default", "")),
            "screenconnectUrl": str(vars_payload.get("screenconnect_machines_url", "")),
            "extraLinks": extra_links,
            "sopOptions": self._get_new_user_sop_options(),
            "taskOptions": [NO_TASK_LINK_OPTION, *self.task_name_options],
        }

    def _client_from_payload(self, payload: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
        name = str(payload.get("name", "")).strip()
        slug = slugify_name(name)
        missing: list[str] = []
        if not name:
            missing.append("Client Name")
        if not slug:
            missing.append("Generated Client ID/Slug")
        if missing:
            return {}, missing

        optional_fields = {
            "itglue_org_id": str(payload.get("itglueOrgId", "")).strip(),
            "itglue_user_create_term_url": str(payload.get("userCreateTermUrl", "")).strip(),
            "itglue_outage_handling_url": str(payload.get("outageHandlingUrl", "")).strip(),
            "itglue_password_primary_admin_id": str(payload.get("primaryAdminPasswordId", "")).strip(),
            "itglue_password_office365_id": str(payload.get("office365PasswordId", "")).strip(),
            "itglue_password_local_admin_id": str(payload.get("localAdminPasswordId", "")).strip(),
            "itglue_password_duo_id": str(payload.get("duoPasswordId", "")).strip(),
            "new_user_sop_default": str(payload.get("newUserSopKey", "")).strip(),
            "screenconnect_machines_url": str(payload.get("screenconnectUrl", "")).strip(),
        }
        vars_payload: dict[str, Any] = {"client_slug": slug}
        for key, value in optional_fields.items():
            if value:
                vars_payload[key] = value

        extra_links = []
        for item in payload.get("extraLinks", []):
            if not isinstance(item, dict):
                continue
            label = str(item.get("label", "")).strip()
            value = str(item.get("value", "")).strip()
            task_name = str(item.get("taskName", "")).strip()
            task_id = "" if not task_name or task_name == NO_TASK_LINK_OPTION else self._resolve_task_id(task_name)
            if label and value:
                extra_links.append({"label": label, "value": value, "task_id": task_id})
        normalized = normalize_extra_links(extra_links, self._resolve_task_id)
        if normalized:
            vars_payload[EXTRA_LINKS_KEY] = normalized
        if "user_termination_sop" in self._get_global_links():
            vars_payload["user_termination_sop"] = "user_termination_sop"
        return {"id": slug, "name": name, "vars": vars_payload}, []

    def _get_new_user_sop_options(self) -> list[str]:
        keys = sorted(self._get_global_links().keys())
        preferred = [key for key in keys if key.lower().startswith("new_user")]
        return preferred if preferred else keys

    def _script_builder_options(self) -> list[dict[str, str]]:
        return [
            {"id": "user_new", "label": "User New"},
            {"id": "user_lockdown", "label": "User Lockdown"},
            {"id": "user_term", "label": "User Term"},
        ]

    def _builder_label(self, builder_id: str) -> str:
        if builder_id == "user_new":
            return "User New"
        if builder_id == "user_lockdown":
            return "User Lockdown"
        return "User Term"

    def _builder_payload(self, builder_id: str, client_name: str = "") -> dict[str, Any]:
        if builder_id == "user_new":
            client = self.client_map.get(self._resolve_client_name(client_name) or client_name.strip())
            canonical_client_name = str(client.get("name", "")).strip() if isinstance(client, dict) else client_name.strip()
            return {
                "id": "user_new",
                "label": "User New",
                "client": canonical_client_name,
                "firstName": "",
                "lastName": "",
                "copyAfter": "",
                "samAccountName": "",
                "userPrincipalName": "",
                "targetOu": "",
                "title": "",
                "department": "",
                "description": "",
                "manager": "",
                "mappedDrives": "",
                "runAdsync": True,
                "mustChange": True,
                "dryRun": True,
                "force": False,
                "resumeExistingUser": False,
                "resumeUserLookup": "",
                "pollSeconds": 5,
                "pollAttempts": 100,
            }

        if builder_id == "user_lockdown":
            client = self.client_map.get(self._resolve_client_name(client_name) or client_name.strip())
            canonical_client_name = str(client.get("name", "")).strip() if isinstance(client, dict) else client_name.strip()
            return {
                "id": "user_lockdown",
                "label": "User Lockdown",
                "client": canonical_client_name,
                "userLookup": "",
                "ticket": "",
                "runAdsync": True,
                "checkEmailRules": True,
                "dryRun": True,
                "force": False,
            }

        client = self.client_map.get(self._resolve_client_name(client_name) or client_name.strip())
        canonical_client_name = str(client.get("name", "")).strip() if isinstance(client, dict) else client_name.strip()
        disabled_ou = self._get_disabled_users_ou(client)
        return {
            "id": "user_term",
            "label": "User Term",
            "client": canonical_client_name,
            "disabledOu": disabled_ou,
            "userLookup": "",
            "ticket": "",
            "groups": ", ".join(DEFAULT_GROUPS_TO_REMOVE),
            "fullAccess": "",
            "sendAs": "",
            "sendOnBehalf": "",
            "convertShared": True,
            "hideGal": True,
            "sentCopy": True,
            "runAdsync": True,
            "dryRun": True,
            "force": False,
            "skipVerified": False,
            "pollSeconds": 10,
            "pollAttempts": 40,
        }

    def _get_disabled_users_ou(self, client: dict[str, Any] | None) -> str:
        if isinstance(client, dict):
            for source in (client, client.get("vars", {})):
                if not isinstance(source, dict):
                    continue
                for key, value in source.items():
                    normalized = "".join(ch for ch in str(key).casefold() if ch.isalnum())
                    if normalized == "disabledusersou":
                        return str(value).strip()
        return ""

    def _focus_window(self) -> None:
        if self.window is None:
            return

        for method_name in ("restore", "show"):
            method = getattr(self.window, method_name, None)
            if method is None:
                continue
            try:
                method()
            except Exception:
                continue

        if os.name == "nt":
            self._force_windows_foreground()

        try:
            self.window.evaluate_js("window.focus && window.focus();")
        except Exception:
            pass

    def _force_windows_foreground(self) -> None:
        native = getattr(self.window, "native", None)
        handle = getattr(native, "Handle", None)
        if handle is None:
            return

        try:
            hwnd = int(handle.ToInt32())
        except Exception:
            return

        try:
            import ctypes

            user32 = ctypes.windll.user32
            kernel32 = ctypes.windll.kernel32
            foreground_hwnd = user32.GetForegroundWindow()
            current_thread_id = kernel32.GetCurrentThreadId()
            foreground_thread_id = (
                user32.GetWindowThreadProcessId(foreground_hwnd, None)
                if foreground_hwnd
                else 0
            )
            target_thread_id = user32.GetWindowThreadProcessId(hwnd, None)
            attached_foreground = False
            attached_target = False
            if foreground_thread_id and foreground_thread_id != current_thread_id:
                attached_foreground = bool(user32.AttachThreadInput(foreground_thread_id, current_thread_id, True))
            if target_thread_id and target_thread_id != current_thread_id:
                attached_target = bool(user32.AttachThreadInput(target_thread_id, current_thread_id, True))

            try:
                user32.ShowWindow(hwnd, 9)
                user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
                user32.SetWindowPos(hwnd, -2, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
                user32.BringWindowToTop(hwnd)
                user32.SetForegroundWindow(hwnd)
                user32.SetActiveWindow(hwnd)
                user32.SetFocus(hwnd)
            finally:
                if attached_target:
                    user32.AttachThreadInput(target_thread_id, current_thread_id, False)
                if attached_foreground:
                    user32.AttachThreadInput(foreground_thread_id, current_thread_id, False)
        except Exception:
            return

    def _generate_script(self, builder_id: str, payload: dict[str, Any]) -> str:
        if builder_id == "user_new":
            return new_user_script(
                template_path=resolve_user_new_template_path(self.app_dir),
                client=str(payload.get("client", "")).strip(),
                first_name=str(payload.get("firstName", "")).strip(),
                last_name=str(payload.get("lastName", "")).strip(),
                copy_after_lookup=str(payload.get("copyAfter", "")).strip(),
                sam_account_name=str(payload.get("samAccountName", "")).strip(),
                user_principal_name=str(payload.get("userPrincipalName", "")).strip(),
                target_ou=str(payload.get("targetOu", "")).strip(),
                title=str(payload.get("title", "")).strip(),
                department=str(payload.get("department", "")).strip(),
                description=str(payload.get("description", "")).strip(),
                manager_lookup=str(payload.get("manager", "")).strip(),
                mapped_drive_letters=str(payload.get("mappedDrives", "")).strip(),
                run_adsync=bool(payload.get("runAdsync", True)),
                must_change_password_at_next_logon=bool(payload.get("mustChange", True)),
                dry_run=bool(payload.get("dryRun", True)),
                force=bool(payload.get("force", False)),
                resume_existing_user=bool(payload.get("resumeExistingUser", False)),
                resume_user_lookup=str(payload.get("resumeUserLookup", "")).strip(),
                poll_seconds=int(payload.get("pollSeconds", 5) or 5),
                poll_attempts=int(payload.get("pollAttempts", 100) or 100),
            )

        if builder_id == "user_lockdown":
            return new_user_lockdown_script(
                template_path=resolve_user_lockdown_template_path(self.app_dir),
                client=str(payload.get("client", "")).strip(),
                user_lookup=str(payload.get("userLookup", "")).strip(),
                ticket_number=str(payload.get("ticket", "")).strip(),
                run_adsync=bool(payload.get("runAdsync", True)),
                check_email_rules=bool(payload.get("checkEmailRules", True)),
                dry_run=bool(payload.get("dryRun", True)),
                force=bool(payload.get("force", False)),
            )

        return new_termination_script(
            template_path=resolve_user_term_template_path(self.app_dir),
            client=str(payload.get("client", "")).strip(),
            disabled_users_ou=str(payload.get("disabledOu", "")).strip(),
            user_lookup=str(payload.get("userLookup", "")).strip(),
            ticket_number=str(payload.get("ticket", "")).strip(),
            groups_to_remove=split_ui_list(str(payload.get("groups", ""))),
            convert_to_shared_mailbox=bool(payload.get("convertShared", True)),
            hide_from_gal=bool(payload.get("hideGal", True)),
            enable_sent_item_copy=bool(payload.get("sentCopy", True)),
            run_adsync=bool(payload.get("runAdsync", True)),
            delegates_full_access=split_ui_list(str(payload.get("fullAccess", ""))),
            delegates_send_as=split_ui_list(str(payload.get("sendAs", ""))),
            delegates_send_on_behalf=split_ui_list(str(payload.get("sendOnBehalf", ""))),
            dry_run=bool(payload.get("dryRun", True)),
            force=bool(payload.get("force", False)),
            skip_if_verified=bool(payload.get("skipVerified", False)),
            poll_seconds=int(payload.get("pollSeconds", 10) or 10),
            poll_attempts=int(payload.get("pollAttempts", 40) or 40),
        )

    def _script_file_name(self, builder_id: str, payload: dict[str, Any]) -> str:
        if builder_id == "user_new":
            return new_user_script_file_name(
                client=str(payload.get("client", "")),
                first_name=str(payload.get("firstName", "")),
                last_name=str(payload.get("lastName", "")),
            )
        if builder_id == "user_lockdown":
            return new_user_lockdown_script_file_name(
                client=str(payload.get("client", "")),
                user_lookup=str(payload.get("userLookup", "")),
                ticket_number=str(payload.get("ticket", "")),
            )
        return new_termination_script_file_name(
            str(payload.get("client", "")),
            str(payload.get("ticket", "")),
            str(payload.get("userLookup", "")),
        )

    def _template_path(self, builder_id: str) -> Path:
        if builder_id == "user_new":
            return resolve_user_new_template_path(self.app_dir)
        if builder_id == "user_lockdown":
            return resolve_user_lockdown_template_path(self.app_dir)
        return resolve_user_term_template_path(self.app_dir)

    def _choose_save_path(self, file_name: str) -> str:
        if self.window is None:
            return ""
        try:
            result = self.window.create_file_dialog(
                webview.SAVE_DIALOG,
                save_filename=file_name,
                file_types=("PowerShell script (*.ps1)", "All files (*.*)"),
            )
        except Exception:
            return ""
        if isinstance(result, (list, tuple)):
            return str(result[0]) if result else ""
        return str(result or "")

    def _get_task_script_builder_id(self, task: dict[str, Any] | None) -> str:
        if not task:
            return ""
        valid_builders = {"user_new", "user_lockdown", "user_term"}
        for key in ("script_builder", "scriptBuilder", "builder"):
            configured = str(task.get(key, "")).strip()
            if configured in valid_builders:
                return configured
        task_id = str(task.get("id", "")).strip()
        fallback = DEFAULT_TASK_SCRIPT_BUILDERS.get(task_id, "")
        if fallback in valid_builders:
            return fallback
        task_name = str(task.get("name", "")).strip().casefold()
        if task_name in {"user term", "user termination"}:
            return "user_term"
        if task_name in {"new user", "user new", "user creation", "new hire", "onboarding"}:
            return "user_new"
        return ""

    @staticmethod
    def _error(message: str) -> dict[str, Any]:
        return {"ok": False, "status": message, "error": message}

    def _hotkey_helper_exe_path(self) -> Path:
        return self.app_dir / HOTKEY_HELPER_EXE_NAME

    def _hotkey_script_path(self) -> Path:
        return self.app_dir / HOTKEY_SCRIPT_NAME

    def _hotkey_payload(self) -> dict[str, Any]:
        running = self._is_hotkey_helper_running()
        return {
            "running": running,
            "text": "hotkey enabled (alt + O/C)" if running else "Enable hotkey",
        }

    def _is_hotkey_script_process_running(self) -> bool:
        if os.name != "nt":
            return False
        script_path = self._hotkey_script_path()
        if not script_path.exists():
            return False
        escaped_script = str(script_path).replace("'", "''")
        powershell_command = (
            f"$scriptPath = '{escaped_script}'; "
            "$proc = Get-CimInstance Win32_Process | Where-Object { "
            "($_.Name -in @('AutoHotkey64.exe','AutoHotkey32.exe','AutoHotkey.exe')) "
            "-and $_.CommandLine -and $_.CommandLine -like \"*$scriptPath*\" } "
            "| Select-Object -First 1; if ($proc) { 'running' }"
        )
        try:
            result = subprocess.run(
                ["powershell", "-NoProfile", "-Command", powershell_command],
                capture_output=True,
                text=True,
                timeout=2,
                check=False,
                creationflags=windows_creationflags(),
            )
        except Exception:
            return False
        return "running" in (result.stdout or "").strip().lower()

    def _is_hotkey_helper_running(self) -> bool:
        if os.name != "nt":
            return False
        helper_exe = self._hotkey_helper_exe_path()
        if helper_exe.exists():
            try:
                result = subprocess.run(
                    ["tasklist", "/FI", f"IMAGENAME eq {HOTKEY_HELPER_EXE_NAME}", "/FO", "CSV", "/NH"],
                    capture_output=True,
                    text=True,
                    timeout=2,
                    check=False,
                    creationflags=windows_creationflags(),
                )
                output = ((result.stdout or "") + (result.stderr or "")).lower()
                return HOTKEY_HELPER_EXE_NAME.lower() in output
            except Exception:
                return False
        return self._is_hotkey_script_process_running()

    def _start_hotkey_helper(self) -> tuple[bool, str]:
        helper_exe = self._hotkey_helper_exe_path()
        if helper_exe.exists():
            try:
                subprocess.Popen([str(helper_exe)], cwd=str(self.app_dir), creationflags=windows_creationflags())
                return True, ""
            except Exception as exc:  # pylint: disable=broad-except
                return False, f"Failed to launch {HOTKEY_HELPER_EXE_NAME}.\n\n{exc}"

        hotkey_script = self._hotkey_script_path()
        if not hotkey_script.exists():
            return False, f"Hotkey helper is missing. Expected either {helper_exe} or {hotkey_script}."

        local_app_data = os.environ.get("LOCALAPPDATA", "")
        candidates: list[Path] = []
        if local_app_data:
            candidates.extend(
                [
                    Path(local_app_data) / "Programs" / "AutoHotkey" / "v2" / "AutoHotkey64.exe",
                    Path(local_app_data) / "Programs" / "AutoHotkey" / "v2" / "AutoHotkey32.exe",
                ]
            )
        candidates.extend(
            [
                Path("C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe"),
                Path("C:/Program Files/AutoHotkey/v2/AutoHotkey32.exe"),
                Path("C:/Program Files (x86)/AutoHotkey/v2/AutoHotkey64.exe"),
                Path("C:/Program Files (x86)/AutoHotkey/v2/AutoHotkey32.exe"),
            ]
        )

        for candidate in candidates:
            if not candidate.exists():
                continue
            try:
                subprocess.Popen([str(candidate), str(hotkey_script)], cwd=str(self.app_dir), creationflags=windows_creationflags())
                return True, ""
            except Exception:
                continue
        return False, "Could not launch hotkey script because AutoHotkey runtime was not found."
