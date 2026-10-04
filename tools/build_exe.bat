@echo off
REM Build the release folder dist\Necromancer (Necromancer.exe + Necromancer.pck + README.txt)
REM and the archive dist\Necromancer.zip.
REM
REM Export templates are NOT used (not installed, do not download them). The trick:
REM   1) export only the resource pack:  --export-pack "Windows Desktop" -> Necromancer.pck
REM   2) copy the stock GUI engine binary next to it as Necromancer.exe.
REM Godot loads "<exe name>.pck" from the exe folder by itself, so the game starts on double click.
REM Preset: godot\export_presets.cfg (feature "ship" turns the MCP bridge off; tests,
REM override.cfg and dev junk are excluded).
REM This file must stay ASCII only (project rule for .bat files).

setlocal
set "ROOT=%~dp0.."
set "GODOT_DIR=C:\Projects\SharedTools\godot"
set "GODOT_CON=%GODOT_DIR%\Godot_v4.7.2-stable_win64_console.exe"
set "GODOT_GUI=%GODOT_DIR%\Godot_v4.7.2-stable_win64.exe"
set "OUT=%ROOT%\dist\Necromancer"
set "ZIP=%ROOT%\dist\Necromancer.zip"

if not exist "%GODOT_CON%" (echo [build] engine not found: %GODOT_CON% & exit /b 1)
if not exist "%GODOT_GUI%" (echo [build] engine not found: %GODOT_GUI% & exit /b 1)

REM 2026-09-25: the build ran while the owner was playing dist\Necromancer\Necromancer.exe;
REM rmdir failed on the locked exe but had already deleted the pck under the running game.
REM Refuse to touch the output while the exe is open.
"%SystemRoot%\System32\tasklist.exe" /FI "IMAGENAME eq Necromancer.exe" 2>nul | "%SystemRoot%\System32\findstr.exe" /I /C:"Necromancer.exe" >nul
if not errorlevel 1 (echo [build] Necromancer.exe is running - close the game first & exit /b 1)
if exist "%OUT%" rmdir /s /q "%OUT%"
if exist "%ZIP%" del /q "%ZIP%"
mkdir "%OUT%" || exit /b 1

echo [build] import
"%GODOT_CON%" --headless --path "%ROOT%\godot" --fixed-fps 60 --import -- --mute >"%ROOT%\dist\import.log" 2>&1
if errorlevel 1 (echo [build] import failed, see dist\import.log & exit /b 1)

echo [build] export pack
"%GODOT_CON%" --headless --path "%ROOT%\godot" --fixed-fps 60 --export-pack "Windows Desktop" "%OUT%\Necromancer.pck" -- --mute >"%ROOT%\dist\export.log" 2>&1
if errorlevel 1 (echo [build] export failed, see dist\export.log & exit /b 1)
if not exist "%OUT%\Necromancer.pck" (echo [build] no pck, see dist\export.log & exit /b 1)

echo [build] engine binary
copy /y "%GODOT_GUI%" "%OUT%\Necromancer.exe" >nul || exit /b 1
copy /y "%ROOT%\tools\release\README.txt" "%OUT%\README.txt" >nul || exit /b 1
copy /y "%ROOT%\tools\release\GODOT_LICENSE.txt" "%OUT%\GODOT_LICENSE.txt" >nul || exit /b 1
REM copy keeps the engine's own date (2026-08-21), so the exe looked stale although the game
REM (the .pck) was fresh. Stamp all release files with the build time.
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%OUT%' | ForEach-Object { $_.LastWriteTime = Get-Date }"

echo [build] zip
REM Python is already required by embed_pck.py; avoid PowerShell 7/5 module-path conflicts.
python -X utf8 -m zipfile -c "%ZIP%" "%OUT%"
if errorlevel 1 (echo [build] zip failed & exit /b 1)

REM Single-file variant (owner request 2026-09-25): the pck is appended to the engine binary
REM with Godot's own trailer (u64 pck size + "GDPC"); the engine finds the pack inside its
REM exe at start, no export templates needed. See tools\embed_pck.py.
set "SINGLE=%ROOT%\dist\Necromancer-single"
if exist "%SINGLE%" rmdir /s /q "%SINGLE%"
mkdir "%SINGLE%" || exit /b 1
echo [build] single-file exe
python -X utf8 "%ROOT%\tools\embed_pck.py" "%OUT%\Necromancer.exe" "%OUT%\Necromancer.pck" "%SINGLE%\Necromancer.exe" >"%ROOT%\dist\embed.log" 2>&1
if errorlevel 1 (echo [build] embed failed, see dist\embed.log & exit /b 1)
copy /y "%ROOT%\tools\release\README.txt" "%SINGLE%\README.txt" >nul || exit /b 1
copy /y "%ROOT%\tools\release\GODOT_LICENSE.txt" "%SINGLE%\GODOT_LICENSE.txt" >nul || exit /b 1
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%SINGLE%' | ForEach-Object { $_.LastWriteTime = Get-Date }"

echo [build] done: %OUT%
echo [build] zip:  %ZIP%
echo [build] single: %SINGLE%\Necromancer.exe
endlocal
