@echo off
set "TARGET=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ClashWifiGuard-autostart.vbs"
if exist "%TARGET%" (
    del "%TARGET%"
    echo Autostart disabled. The Startup entry was removed.
) else (
    echo Autostart was not enabled.
)
echo.
pause
