@echo off
setlocal
REM One-click setup for system proxy using local PAC server (localhost).
REM Copies files to %ProgramData%\CompanyProxy and configures current user's proxy settings.

set "BASE=%ProgramData%\CompanyProxy"
if not exist "%BASE%" mkdir "%BASE%"

copy /Y "%~dp0proxy.pac"      "%BASE%\proxy.pac"      >nul
copy /Y "%~dp0PacServer.ps1"  "%BASE%\PacServer.ps1"  >nul
copy /Y "%~dp0SetupProxy.ps1" "%BASE%\SetupProxy.ps1" >nul
copy /Y "%~dp0DisableProxy.ps1" "%BASE%\DisableProxy.ps1" >nul

REM Create scheduled task to run at logon (per-user)
schtasks /Create /F /SC ONLOGON /TN "CompanyProxy PAC Server" ^
 /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%BASE%\PacServer.ps1\"" >nul 2>&1

REM Start server now (hidden)
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%BASE%\PacServer.ps1"

REM Configure Windows to use PAC and disable auto-detect + manual proxy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%\SetupProxy.ps1" -Port 8787

echo.
echo DONE. Restart your browser if it was already open.
pause
endlocal
