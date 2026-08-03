from __future__ import annotations

import csv
import re
from datetime import datetime
from pathlib import Path
from typing import Any

from ..shared.powershell_partials import inline_powershell_tools


DEFAULT_GROUPS_TO_REMOVE = ("UserCentric", "ConnectActive")


def powershell_single_quoted(value: Any) -> str:
    text = "" if value is None else str(value)
    return "'" + text.replace("'", "''") + "'"


def powershell_array_literal(values: list[str] | tuple[str, ...]) -> str:
    clean_values = []
    seen: set[str] = set()
    for value in values:
        cleaned = str(value).strip()
        if not cleaned:
            continue
        key = cleaned.casefold()
        if key in seen:
            continue
        seen.add(key)
        clean_values.append(cleaned)

    if not clean_values:
        return "@()"

    return "@(" + ", ".join(powershell_single_quoted(value) for value in clean_values) + ")"


def powershell_bool_literal(value: bool) -> str:
    return "$true" if value else "$false"


def split_ui_list(text: str) -> list[str]:
    if not text.strip():
        return []

    values: list[str] = []
    seen: set[str] = set()
    for item in re.split(r"[\r\n,;]+", text):
        cleaned = item.strip()
        if not cleaned:
            continue
        key = cleaned.casefold()
        if key in seen:
            continue
        seen.add(key)
        values.append(cleaned)
    return values


def normalize_line_endings(text: str) -> str:
    return re.sub(r"\r\n|\n|\r", "\r\n", text or "")


def safe_file_name_part(value: str) -> str:
    cleaned = str(value or "").strip()
    if not cleaned:
        return "unknown"

    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]+', "-", cleaned)
    cleaned = re.sub(r"\s+", "-", cleaned)
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", cleaned).strip("-")
    return cleaned or "unknown"


def new_termination_script_file_name(client: str, ticket_number: str, user_lookup: str) -> str:
    return "Terminate-{0}-{1}-{2}.ps1".format(
        safe_file_name_part(client),
        safe_file_name_part(ticket_number),
        safe_file_name_part(user_lookup),
    )


def resolve_template_path(app_dir: Path) -> Path:
    candidates = [
        app_dir / "script_builders" / "user_term" / "template_user_term.ps1",
        Path(__file__).resolve().parent / "template_user_term.ps1"
    ]

    for candidate in candidates:
        if candidate.exists():
            return candidate

    return candidates[0]


def resolve_client_csv_path(app_dir: Path) -> Path:
    candidates = [
        app_dir / "script_builders" / "user_term" / "ClientOUs.csv",
        Path(__file__).resolve().parent / "ClientOUs.csv",
        Path.home() / "Documents" / "projects" / "Automation" / "User_term" / "ClientOUs.csv",
    ]

    for candidate in candidates:
        if candidate.exists():
            return candidate

    return candidates[0]


def load_client_ou_rows(csv_path: Path) -> list[dict[str, str]]:
    if not csv_path.exists():
        return []

    rows: list[dict[str, str]] = []
    with csv_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            client = str(row.get("Client", "")).strip()
            if not client:
                continue
            rows.append(
                {
                    "Client": client,
                    "DisabledUsersOU": str(row.get("DisabledUsersOU", "")).strip(),
                }
            )

    rows.sort(key=lambda row: row["Client"].casefold())
    return rows


def _slug(value: str) -> str:
    lowered = value.strip().casefold()
    return re.sub(r"[^a-z0-9]+", "_", lowered).strip("_")


def find_client_ou(rows: list[dict[str, str]], client_name: str) -> str:
    cleaned = client_name.strip()
    if not cleaned:
        return ""

    cleaned_slug = _slug(cleaned)
    for row in rows:
        row_client = row.get("Client", "")
        if row_client.casefold() == cleaned.casefold() or _slug(row_client) == cleaned_slug:
            return row.get("DisabledUsersOU", "").strip()
    return ""


def new_termination_script(
    *,
    template_path: Path,
    client: str,
    disabled_users_ou: str,
    user_lookup: str,
    ticket_number: str,
    groups_to_remove: list[str],
    convert_to_shared_mailbox: bool,
    hide_from_gal: bool,
    enable_sent_item_copy: bool,
    run_adsync: bool,
    delegates_full_access: list[str],
    delegates_send_as: list[str],
    delegates_send_on_behalf: list[str],
    dry_run: bool,
    force: bool,
    skip_if_verified: bool,
    poll_seconds: int,
    poll_attempts: int,
) -> str:
    if not template_path.exists():
        raise FileNotFoundError(f"Template script was not found: {template_path}")
    if not client.strip():
        raise ValueError("Client is required.")
    if not user_lookup.strip():
        raise ValueError("User lookup is required.")
    if not ticket_number.strip():
        raise ValueError("Ticket number is required.")
    if poll_seconds < 1:
        raise ValueError("Poll seconds must be at least 1.")
    if poll_attempts < 1:
        raise ValueError("Poll attempts must be at least 1.")

    template = template_path.read_text(encoding="utf-8-sig")
    template = inline_powershell_tools(template, template_path.parents[2])
    generated_at = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    config_block = f"""# -------------------------
# Generated by Stuff Opener Script Builders on {generated_at}.
# -------------------------

# If DisabledUsersOU is blank, the script searches the DC:
$Client = {powershell_single_quoted(client)}
$DisabledUsersOU = {powershell_single_quoted(disabled_users_ou)}
$UserLookup = {powershell_single_quoted(user_lookup)}
$TicketNumber = {powershell_single_quoted(ticket_number)}
$GroupsToRemove = {powershell_array_literal(groups_to_remove)}

# Mailbox options:
$ConvertToSharedMailbox = {powershell_bool_literal(convert_to_shared_mailbox)}
$HideFromGAL = {powershell_bool_literal(hide_from_gal)}
$EnableSentItemCopy = {powershell_bool_literal(enable_sent_item_copy)}

# Delegates Assignments:
$DelegatesFullAccess = {powershell_array_literal(delegates_full_access)}
$DelegatesSendAs = {powershell_array_literal(delegates_send_as)}
$DelegatesSendOnBehalf = {powershell_array_literal(delegates_send_on_behalf)}

# Run options:
$DryRun = {powershell_bool_literal(dry_run)}
$Force = {powershell_bool_literal(force)}
$SkipIfVerified = {powershell_bool_literal(skip_if_verified)}
$PollSeconds = {poll_seconds}
$PollAttempts = {poll_attempts}
$RunADSync = {powershell_bool_literal(run_adsync)}

"""

    top_block_pattern = (
        r"(?ms)# -------------------------\r?\n"
        r"# Fill these in per ticket\.\r?\n"
        r"# -------------------------\r?\n"
        r".*?(?=\r?\n# -------------------------\r?\n# 0\.5\. Prep work:)"
    )
    script, replacement_count = re.subn(top_block_pattern, config_block, template, count=1)
    if replacement_count != 1:
        raise ValueError("Could not find the top ticket config block in the template.")

    return normalize_line_endings(script)
