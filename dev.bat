@echo off
REM Hugo development server shortcut
setlocal enabledelayedexpansion

set "HUGO_BIN=%APPDATA%\hugo"

set "PATH=!HUGO_BIN!;!PATH!"

REM Navigate to script directory (works from anywhere)
cd /d "%~dp0"

hugo.exe server -D --port 1414

pause
