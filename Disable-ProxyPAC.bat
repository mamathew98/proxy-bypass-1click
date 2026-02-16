@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ProgramData%\CompanyProxy\DisableProxy.ps1"
echo.
pause
endlocal
