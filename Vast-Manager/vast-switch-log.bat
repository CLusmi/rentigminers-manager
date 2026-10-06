@echo off
rem Lance vast-switch-log.ps1 (dans le meme dossier) sans changer les reglages de Windows.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vast-switch-log.ps1" %*
if errorlevel 1 pause
