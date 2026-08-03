"""Registry for script builders available in the WebView UI."""

BUILDER_LABELS = {
    "user_new": "User New",
    "user_lockdown": "User Lockdown",
    "user_term": "User Term",
}

# Kept for compatibility with older imports. UI classes were removed during the
# PyWebView migration; the active frontend calls generator functions directly.
BUILDER_CLASSES: dict[str, object] = {}
