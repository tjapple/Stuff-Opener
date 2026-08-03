# Stuff Opener

Stuff Opener is a Windows desktop launcher for repeatable IT support workflows. It combines client and task selection, validated browser links, and self-contained PowerShell script builders in one local-first interface.

This repository contains fictional demonstration data only. Real organization, customer, credential, tenant, and deep-link data belongs in a local ignored configuration file and must never be committed or attached to a public release.

## Features

- Searchable organization and workflow selectors.
- One-click launch of task links, documentation, password records, and remote-support pages.
- HTTPS and hostname allowlist validation before opening external links.
- In-app organization configuration editor.
- Self-contained PowerShell builders for common user lifecycle workflows.
- Optional global hotkey helper and Windows installer packaging.
- Per-user runtime configuration stored outside the repository.

## Technology

- Python 3.10+
- pywebview desktop shell
- HTML, CSS, and JavaScript frontend
- PowerShell automation templates
- AutoHotkey v2 hotkey helper
- PyInstaller and Inno Setup packaging

## Run from source

Install [uv](https://docs.astral.sh/uv/), then run:

```powershell
uv sync --locked
.\run.cmd
```

On first launch, the app copies `config.example.json` to the per-user runtime location. The example contains only fictional values.

## Configuration

The app checks these seed files in order:

1. `default_config.json` — generated inside packaged builds.
2. `config.local.json` — optional local development override.
3. `config.json` — optional backwards-compatible local override.
4. `config.example.json` — tracked fictional fallback.

The active runtime file is stored at:

```text
%LOCALAPPDATA%\StuffOpener\config.json
```

To use private data during local development, copy the example and edit the ignored local file:

```powershell
Copy-Item config.example.json config.local.json
```

Do not place secrets in configuration. Stuff Opener is designed to open URLs using existing browser sessions; it does not need API tokens or passwords.

## Keyboard shortcuts

In the app:

- `Ctrl+L` launches workflow links and selected checklist items.
- `Ctrl+Shift+L` launches selected checklist items only.

The optional AutoHotkey helper uses `Alt+O` to focus or launch Stuff Opener.

## Tests

Run Python validation tests:

```powershell
uv run python -m unittest discover -s tests -p "test_*.py" -v
```

Run the PowerShell test suite when Pester is installed:

```powershell
.\tests\powershell\Run-PesterTests.ps1
```

The PowerShell tests use mocks and fixtures; they do not connect to a live Active Directory, Microsoft Graph, Exchange Online, or customer tenant.

## Build a Windows installer

Build prerequisites:

- uv
- AutoHotkey v2 with Ahk2Exe
- Inno Setup 6

The safe public build packages `config.example.json` automatically:

```powershell
.\packaging\build-package.ps1 -Version "0.1.0"
```

Output is written under `dist\release\`, which is ignored by Git.

A private configuration can be embedded only through an explicit override:

```powershell
.\packaging\build-package.ps1 `
  -Version "0.1.0-internal" `
  -ConfigPath .\config.local.json `
  -AllowPrivateConfig
```

That installer contains the selected configuration in recoverable form. It is for private distribution only and must never be uploaded to a public GitHub Release.

## Security model

- Runtime data remains local to the current user.
- Generated links must use HTTPS and match configured hostname suffixes.
- Path identifiers are validated before URL construction.
- Local configuration, generated outputs, build artifacts, and common credential file types are ignored by Git.
- Public release builds use fictional data unless a maintainer deliberately overrides the safety check.

See [SECURITY.md](SECURITY.md) for reporting and data-handling guidance.

## Project status

Stuff Opener is a portfolio project and practical desktop automation tool. Test integrations against a lab environment before using generated scripts in production.
