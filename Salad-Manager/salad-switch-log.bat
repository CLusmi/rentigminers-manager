@echo off
rem Lance salad-switch-log.ps1 (dans le meme dossier) sans changer les reglages de Windows.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0salad-switch-log.ps1" %*
if errorlevel 1 pause
