from __future__ import annotations

from typing import Any


def build_client_task_state(config: dict[str, Any]) -> dict[str, Any]:
    clients = sorted(config["clients"], key=lambda c: str(c.get("name", "")).lower())
    tasks = list(config["tasks"])

    client_name_options = [str(client.get("name", "")).strip() for client in clients]
    client_name_options = [name for name in client_name_options if name]
    client_map = {str(client.get("name", "")): client for client in clients}
    client_casefold_map = {name.casefold(): name for name in client_name_options}

    task_name_options = [str(task.get("name", "")).strip() for task in tasks]
    task_name_options = [name for name in task_name_options if name]
    task_name_options.sort(key=lambda name: name.lower())
    task_map = {str(task.get("name", "")): task for task in tasks}
    task_casefold_map = {name.casefold(): name for name in task_name_options}
    task_id_map = {
        str(task.get("id", "")).strip(): task
        for task in tasks
        if str(task.get("id", "")).strip()
    }

    return {
        "clients": clients,
        "tasks": tasks,
        "client_name_options": client_name_options,
        "client_map": client_map,
        "client_casefold_map": client_casefold_map,
        "task_name_options": task_name_options,
        "task_map": task_map,
        "task_casefold_map": task_casefold_map,
        "task_id_map": task_id_map,
    }


def resolve_casefold_name(typed_name: str, casefold_map: dict[str, str]) -> str | None:
    return casefold_map.get(typed_name.strip().casefold())
