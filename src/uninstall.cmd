@echo off
rem Double-click entry point for dsh-web-uninstall.ps1.
rem ASCII only on purpose: the Chinese output comes from the PowerShell script,
rem which is written as UTF-8 with BOM so Windows PowerShell reads it correctly.
setlocal

rem Leave the install directory immediately: a directory that is some process's
rem current working directory cannot be removed, and the cleanup below has to
rem delete this one. Doing it before the pause also means the detached cleanup
rem never has to wait for a keypress.
cd /d "%TEMP%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-web-uninstall.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
pause

rem Keep both files when the run was cancelled or failed, so it can be retried.
if not "%RC%"=="0" exit /b

rem PowerShell can still hold the script handle for a moment after it exits, so retry.
set "PS1=%~dp0dsh-web-uninstall.ps1"
for /l %%i in (1,1,5) do (
  if exist "%PS1%" (
    del /f /q "%PS1%" 2>nul
    if exist "%PS1%" timeout /t 1 >nul
  )
)

rem The now-empty directory is removed by the detached cleanup script that
rem dsh-web-uninstall.ps1 scheduled, so no stray cmd error reaches the user.

(goto) 2>nul & del /f /q "%~f0"
