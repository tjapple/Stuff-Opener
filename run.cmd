@echo off
setlocal
cd /d "%~dp0"

where uv >nul 2>&1
if errorlevel 1 (
    echo uv was not found. Install uv, then run: uv sync --locked
    exit /b 1
)

echo Starting Stuff Opener from the repository.
echo This is a development launch; it does not install the app or create shortcuts.
echo.

uv run --locked --no-sync python app.py
if errorlevel 1 (
    echo.
    echo Launch failed. Run "uv sync --locked" first, then try again.
    exit /b 1
)
