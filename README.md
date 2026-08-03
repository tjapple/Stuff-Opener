# Stuff Opener
Stuff Opener is a Windows desktop launcher for repeatable IT support workflows. It combines client and task selection, validated browser links, and self-contained PowerShell script builders in one local-first interface.

This repository contains fictional demonstration data only. Real organization, customer, credential, tenant, and deep-link data belongs in a local ignored configuration file and must never be committed or attached to a public release.

Since everything can be tweaked directly in the config file, this app could be used for all sorts of different things - not just IT workflows. Think of it as a platform to launch saved URLs or programs, bundle tasks/documents into task packages, and assemble custom scripts - all from the click of a few buttons. Hotkeys are built-in and customizable, enabling friction-free workflows. 

<img width="1261" height="810" alt="image" src="https://github.com/user-attachments/assets/b28ab3d3-9ac5-4c9e-bc86-4a6ea8405c9a" />
<img width="1843" height="915" alt="image" src="https://github.com/user-attachments/assets/6756525d-07d7-4bf5-9c31-3591e278a3f5" />


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

## Install Stuff Opener

For a normal installation, download `StuffOpener-Setup-<version>.exe` from the repository's GitHub Releases page and run it. The per-user installer does not require administrator access.

Setup installs the app under `%LOCALAPPDATA%\StuffOpener`, adds a Start menu shortcut, and optionally creates a desktop shortcut. Published portfolio builds are not code-signed, so Windows may show a reputation warning; only run an installer downloaded from this repository's Releases page.

Running `run.cmd` from a clone is a development launch. It does **not** install the app or create shortcuts.

## Run temporarily from source

Install [uv](https://docs.astral.sh/uv/), then run:

```powershell
uv sync --locked
.\run.cmd
```

On first launch, the app copies `config.example.json` to the per-user runtime location. The example contains only fictional values. Closing this development launch leaves no installed application behind; rerun `run.cmd` to start it again.

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

The optional AutoHotkey helper uses `Alt+O` to focus or launch Stuff Opener. `Alt+C` will snap focus to the client dropdown (start of the workflow). 

# Development
- Please clone this repo and do whatever you'd like with it. Make it your own. It is highly customizable. It also includes packaging flows so you can clone this, customize it, and build an installer file. 

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

This section is for maintainers building release artifacts, not for end users installing the app.

Build prerequisites:

- [uv](https://docs.astral.sh/uv/)
- [Inno Setup 6](https://jrsoftware.org/isdl.php)
- Optional hotkey build: [AutoHotkey v2](https://www.autohotkey.com/) and Ahk2Exe

Ahk2Exe is a separate compiler component. After installing AutoHotkey v2, open **AutoHotkey Dash** from the Start menu, choose **Compile**, and approve its compiler download.

Run the fast preflight first. Use the `.cmd` wrapper so no permanent PowerShell execution-policy change is needed:

```powershell
.\packaging\build-package.cmd -PreflightOnly
```

The safe public build packages `config.example.json` automatically:

```powershell
.\packaging\build-package.cmd -Version "0.1.0"
```

The installer is written to `dist\release\installer\StuffOpener-Setup-0.1.0.exe`. Run that file to verify the actual install, Start menu shortcut, and uninstall flow. Everything under `dist\release\` is generated and ignored by Git.

To build without installing AutoHotkey or Ahk2Exe, omit the compiled global hotkey helper:

```powershell
.\packaging\build-package.cmd -Version "0.1.0" -SkipHotkeyHelper
```

That installer still includes the `.ahk` source for users who already have AutoHotkey v2, but it does not install or automatically start a compiled hotkey executable.

The preflight recognizes per-user, system-wide, registry-registered, `v2`, and versioned AutoHotkey installations. Nonstandard portable installations can be supplied with `-AutoHotkeyRoot`, `-AhkBasePath`, `-Ahk2ExePath`, or `-InnoSetupPath`.

A private configuration can be embedded only through an explicit override:

```powershell
.\packaging\build-package.cmd `
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
