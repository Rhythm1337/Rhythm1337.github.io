@echo off
REM Hugo development server shortcut
setlocal enabledelayedexpansion

set "GO_BIN=%APPDATA%\go\bin"
set "HUGO_BIN=%APPDATA%\hugo"

set "PATH=!GO_BIN!;!HUGO_BIN!;!PATH!"

REM Navigate to script directory (works from anywhere)
cd /d "%~dp0"

hugo.exe server -D

pause
