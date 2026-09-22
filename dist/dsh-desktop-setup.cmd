@echo off
rem Double-click entry point for dsh-desktop-setup.ps1 - the installer for a
rem personal DeepSeek Harness desktop build.
rem
rem With no arguments it asks for four things through dialogs:
rem   1. the local path of your deepseek-harness clone
rem   2. a custom icon file (any image; square works best)
rem   3. where the accompanying files go  (launcher, config, icon, browser data)
rem   4. which folder the shortcut goes in (usually the desktop)
rem
rem Power users can pass them directly instead:
rem   dsh-desktop-setup.cmd -RepoPath "D:\path\to\deepseek-harness" ^
rem                         -IconFile "D:\path\to\icon.png" ^
rem                         -InstallDir "%LOCALAPPDATA%\dsh-desktop" ^
rem                         -ShortcutDir "%USERPROFILE%\Desktop" ^
rem                         -Port 3080 -ShortcutName "My DSH" -Silent
rem
rem ASCII only on purpose: the Chinese output comes from the PowerShell script,
rem which is written as UTF-8 with BOM so Windows PowerShell reads it correctly.
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-desktop-setup.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
pause
exit /b %RC%
