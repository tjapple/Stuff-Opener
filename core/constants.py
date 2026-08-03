from __future__ import annotations


APP_NAME = "StuffOpener"

UI_CONFIG_KEY = "ui"
UI_THEME_CONFIG_KEY = "theme"

DEFAULT_CONFIG_FILENAMES = (
    "default_config.json",
    "config.local.json",
    "config.json",
    "config.example.json",
)

INSTANCE_HOST = "127.0.0.1"
INSTANCE_PORT = 48651

PASSWORD_URL_KEY_PREFIX = "itglue_password_"
EXTRA_LINKS_KEY = "extra_links"
NO_TASK_LINK_OPTION = "Not tied to a task"

ALLOWED_URL_SCHEMES = {"https"}
DEFAULT_ALLOWED_HOST_SUFFIXES = (
    "itglue.com",
    "screenconnect.com",
    "duosecurity.com",
)

DEFAULT_SELECTED_PASSWORDS = {"office365", "primaryadmin"}
PASSWORD_DISPLAY_PRIORITY = {
    "office365": 0,
    "primaryadmin": 1,
    "localadmin": 2,
}

WINDOWS_APP_ID = "StuffOpener.Desktop"
HOTKEY_HELPER_EXE_NAME = "stuff-opener-hotkey.exe"
HOTKEY_SCRIPT_NAME = "stuff-opener-hotkey.ahk"

USER_TERMINATION_TASK_ID = "user_termination"
DEFAULT_TASK_SCRIPT_BUILDERS = {
    "new_user": "user_new",
    "user_creation": "user_new",
    "user_lockdown": "user_lockdown",
    "account_lockdown": "user_lockdown",
    "user_compromise": "user_lockdown",
    USER_TERMINATION_TASK_ID: "user_term",
}
SCRIPT_BUILDER_REFOCUS_DELAYS_MS = (150, 600, 1400, 2600, 4200, 6500, 9000, 12000)
